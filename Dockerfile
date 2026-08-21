# syntax=docker/dockerfile:1.7

ARG NUXEO_BUILD_IMAGE=maven:3.9.9-eclipse-temurin-21
ARG NUXEO_DISTRIB_IMAGE=azul/zulu-openjdk:21
ARG NUXEO_RUNTIME_IMAGE=oraclelinux:9-slim
ARG NUXEO_WEBUI_GIT_REF
ARG NUXEO_WEBUI_VERSION

FROM ${NUXEO_BUILD_IMAGE} AS source-tree

ARG NUXEO_SOURCE_ARCHIVE_URL
ARG NUXEO_GIT_REF

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/nuxeo

RUN curl -fsSL "${NUXEO_SOURCE_ARCHIVE_URL}" -o /tmp/nuxeo-source.tar.gz \
 && tar -xzf /tmp/nuxeo-source.tar.gz --strip-components=1 -C /workspace/nuxeo \
 && rm -f /tmp/nuxeo-source.tar.gz \
 && printf '%s\n' "${NUXEO_GIT_REF}" > /workspace/nuxeo/.nuxeo-source-ref

FROM source-tree AS source-build

ARG NUXEO_BUILD_THREADS=6

ENV MAVEN_OPTS="-Xmx4g -Xms2g -XX:+TieredCompilation -XX:TieredStopAtLevel=1"

RUN --mount=type=cache,id=nuxeo-maven,target=/root/.m2 \
    mvn -nsu install -N \
 && mvn -nsu install -N -f parent/pom.xml \
 && mvn -nsu install -Pdistrib -pl server/nuxeo-server-tomcat -am \
      -DskipTests \
      -Dnuxeo.skip.enforcer=true \
      -T"${NUXEO_BUILD_THREADS}" \
 && mvn -nsu -q -N -f parent/pom.xml \
      help:evaluate -Dexpression=project.version -DforceStdout \
      > /workspace/nuxeo/.nuxeo-parent-version

RUN mkdir -p /build-output \
 && cp server/nuxeo-server-tomcat/target/nuxeo-server-tomcat-*.zip /build-output/nuxeo-server-tomcat.zip \
 && cp .nuxeo-source-ref /build-output/nuxeo-source-ref.txt \
 && cp .nuxeo-parent-version /build-output/nuxeo-parent-version.txt

FROM ${NUXEO_BUILD_IMAGE} AS facets-bundle

WORKDIR /workspace/facets-bundle

COPY config/content-lake-facets-contrib.xml /workspace/facets-bundle/OSGI-INF/content-lake-facets-contrib.xml
COPY config/schema/content-lake-scope.xsd /workspace/facets-bundle/schema/content-lake-scope.xsd

RUN mkdir -p /workspace/facets-bundle/META-INF /build-output \
 && printf '%s\n' \
      'Manifest-Version: 1.0' \
      'Bundle-ManifestVersion: 2' \
      'Bundle-Name: Content Lake Facets' \
      'Bundle-SymbolicName: org.hyland.contentlake.facets' \
      'Bundle-Version: 1.0.0' \
      'Nuxeo-Component: OSGI-INF/content-lake-facets-contrib.xml' \
      > /workspace/facets-bundle/META-INF/MANIFEST.MF \
 && jar cfm /build-output/content-lake-facets-bundle.jar \
      /workspace/facets-bundle/META-INF/MANIFEST.MF \
      -C /workspace/facets-bundle OSGI-INF \
      -C /workspace/facets-bundle schema

FROM ${NUXEO_BUILD_IMAGE} AS ui-overlay-bundle

WORKDIR /workspace/ui-bundle

COPY ui-bundle/META-INF/MANIFEST.MF /workspace/ui-bundle/META-INF/MANIFEST.MF
COPY ui-bundle/OSGI-INF/deployment-fragment.xml /workspace/ui-bundle/OSGI-INF/deployment-fragment.xml
COPY ui/index.jsp /workspace/ui-bundle/web/nuxeo.war/ui/index.jsp
COPY ui/nuxeo-custom-bundle.html /workspace/ui-bundle/web/nuxeo.war/ui/nuxeo-custom-bundle.html
COPY ui/content-lake-folder-control.html /workspace/ui-bundle/web/nuxeo.war/ui/content-lake-folder-control.html

RUN mkdir -p /build-output \
 && jar cfm /build-output/content-lake-ui-bundle.jar \
      /workspace/ui-bundle/META-INF/MANIFEST.MF \
      -C /workspace/ui-bundle OSGI-INF \
      -C /workspace/ui-bundle web

FROM ${NUXEO_BUILD_IMAGE} AS web-ui-build

ARG NUXEO_WEBUI_GIT_REF
ARG NUXEO_WEBUI_VERSION

# Node 20 (from NodeSource), not Debian's distro nodejs (18.x): the nuxeo-web-ui build's
# copy-webpack-plugin uses Array.prototype.toSorted(), which requires Node >= 20.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/web-ui

RUN curl -fsSL "https://github.com/nuxeo/nuxeo-web-ui/archive/${NUXEO_WEBUI_GIT_REF}.tar.gz" \
      -o /tmp/nuxeo-web-ui-source.tar.gz \
 && tar -xzf /tmp/nuxeo-web-ui-source.tar.gz --strip-components=1 \
 && rm /tmp/nuxeo-web-ui-source.tar.gz

# The nuxeo-web-ui pom declares a fixed nuxeo-parent release version (behind Nuxeo Connect auth).
# The source-build stage builds nuxeo-parent from the pinned Nuxeo source into the shared Maven
# cache (id=nuxeo-maven) and records the exact version it produced. Patch the web-ui parent to
# that version, read from the emitted file, so the two never drift and no version is hardcoded.
# Copying these files also forces ordering: source-build must complete (and populate the shared
# Maven cache) before this build runs.
COPY --from=source-build /build-output/nuxeo-parent-version.txt /tmp/nuxeo-parent-version.txt
COPY --from=source-build /build-output/nuxeo-source-ref.txt /tmp/nuxeo-source-ref.txt
RUN NUXEO_PARENT_VERSION="$(tr -d '[:space:]' < /tmp/nuxeo-parent-version.txt)" \
 && test -n "$NUXEO_PARENT_VERSION" || { echo "empty nuxeo-parent version from source-build" >&2; exit 1; } \
 && echo "Patching nuxeo-web-ui parent to nuxeo-parent:${NUXEO_PARENT_VERSION}" \
 && sed -i "/nuxeo-parent/{n;s|<version>[^<]*</version>|<version>${NUXEO_PARENT_VERSION}</version>|}" pom.xml

RUN --mount=type=cache,id=nuxeo-maven,target=/root/.m2 \
    printf '%s\n' \
      '<settings>' \
      '  <mirrors>' \
      '    <mirror>' \
      '      <id>nuxeo-public-mirror</id>' \
      '      <mirrorOf>maven-internal</mirrorOf>' \
      '      <url>https://packages.nuxeo.com/repository/maven-public/</url>' \
      '    </mirror>' \
      '  </mirrors>' \
      '  <profiles><profile><id>nuxeo-public</id>' \
      '    <repositories><repository><id>nuxeo-public</id>' \
      '      <url>https://packages.nuxeo.com/repository/maven-public/</url>' \
      '    </repository></repositories>' \
      '    <pluginRepositories><pluginRepository><id>nuxeo-public</id>' \
      '      <url>https://packages.nuxeo.com/repository/maven-public/</url>' \
      '    </pluginRepository></pluginRepositories>' \
      '  </profile></profiles>' \
      '  <activeProfiles><activeProfile>nuxeo-public</activeProfile></activeProfiles>' \
      '</settings>' > /tmp/nuxeo-web-ui-settings.xml \
 && mvn -nsu -s /tmp/nuxeo-web-ui-settings.xml install \
      -DskipTests -DskipITs \
      -pl plugin/web-ui/marketplace -am \
 && mkdir -p /build-output \
 && webui_zip="$(ls plugin/web-ui/marketplace/target/nuxeo-web-ui-marketplace-*.zip | head -1)" \
 && test -n "$webui_zip" || { echo "no nuxeo-web-ui marketplace zip produced" >&2; exit 1; } \
 && cp "$webui_zip" /build-output/nuxeo-web-ui-marketplace.zip \
 && basename "$webui_zip" | sed 's|^nuxeo-web-ui-marketplace-||; s|\.zip$||' \
      > /build-output/nuxeo-web-ui-version.txt

FROM ${NUXEO_DISTRIB_IMAGE} AS distribution

RUN apt-get update \
 && apt-get install -y --no-install-recommends procps unzip \
 && rm -rf /var/lib/apt/lists/*

COPY --from=source-build /build-output/nuxeo-server-tomcat.zip /tmp/nuxeo-distribution-tomcat.zip

ENV NUXEO_HOME=/distrib

RUN mkdir -p /tmp/nuxeo-distribution \
 && unzip -q -d /tmp/nuxeo-distribution /tmp/nuxeo-distribution-tomcat.zip \
 && DISTDIR=$(/bin/ls /tmp/nuxeo-distribution | head -n 1) \
 && mv /tmp/nuxeo-distribution/"${DISTDIR}" "${NUXEO_HOME}" \
 && sed -i -e "s/^org.nuxeo.distribution.package.*/org.nuxeo.distribution.package=docker/" "${NUXEO_HOME}/templates/common/config/distribution.properties" \
 && mkdir -p "${NUXEO_HOME}/packages/backup" \
 && mkdir -p "${NUXEO_HOME}/packages/store" \
 && mkdir -p "${NUXEO_HOME}/packages/tmp" \
 && rm -rf /tmp/nuxeo-distribution* \
 && chmod +x "${NUXEO_HOME}"/bin/*ctl "${NUXEO_HOME}"/bin/*.sh \
 && chmod -R g+rwX "${NUXEO_HOME}"

FROM ${NUXEO_RUNTIME_IMAGE}

ARG NUXEO_GIT_TRACK
ARG NUXEO_GIT_REF
ARG NUXEO_WEBUI_VERSION

LABEL org.opencontainers.image.title="Nuxeo local deployment"
LABEL org.opencontainers.image.description="Local Nuxeo runtime built from the public nuxeo/nuxeo source tree"
LABEL org.opencontainers.image.source="https://github.com/nuxeo/nuxeo"
LABEL org.opencontainers.image.revision="${NUXEO_GIT_REF}"
LABEL org.opencontainers.image.version="${NUXEO_GIT_TRACK}"
LABEL org.nuxeo.git-track="${NUXEO_GIT_TRACK}"
LABEL org.nuxeo.web-ui.version="${NUXEO_WEBUI_VERSION}"

COPY --from=source-tree /workspace/nuxeo/docker/nuxeo/nuxeo-public.repo /etc/yum.repos.d/nuxeo-public.repo

RUN rpm --import https://repos.azulsystems.com/RPM-GPG-KEY-azulsystems \
 && rpm --install https://cdn.azul.com/zulu/bin/zulu-repo-1.0.0-1.noarch.rpm \
 && microdnf -y update \
 && microdnf -y install dnf shadow-utils \
 && dnf -y install epel-release \
 && dnf config-manager --set-enabled ol9_codeready_builder \
 && dnf -y install --nogpgcheck https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-9.noarch.rpm \
 && dnf -y install \
    ImageMagick \
    ffmpeg \
    findutils \
    ghostscript \
    libreoffice \
    poppler-utils \
    procps \
    unzip \
    wget \
    zulu21-jre-headless \
 && dnf clean all \
 && rm -rf /var/cache /var/tmp/* \
 && update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-21-zulu-openjdk-ca/bin/java 2100

# zulu21-jre-headless is a meta-package; the JRE lands in java-21-zulu-openjdk-ca.
# LibreOffice pulls in Java 17 -- pin JAVA_HOME and PATH to Zulu 21 so nuxeoctl
# and the running container always use the right JVM.
ENV JAVA_HOME=/usr/lib/jvm/java-21-zulu-openjdk-ca
ENV PATH=${JAVA_HOME}/bin:${PATH}

RUN find /var/log -type f -delete \
 && find / -ignore_readdir_race -perm 6000 -type f -exec chmod a-s {} \; || true

RUN chmod g=u /etc/passwd \
 && useradd -m -d /home/nuxeo -u 900 -s /bin/bash nuxeo

ENV LANG=en_US.utf8
ENV NUXEO_USER=nuxeo
ENV NUXEO_HOME=/opt/nuxeo/server
ENV NUXEO_CONF=/etc/nuxeo/nuxeo.conf
ENV PATH=${NUXEO_HOME}/bin:${PATH}

COPY --from=source-tree --chown=900:0 /workspace/nuxeo/docker/nuxeo/rootfs/ /
COPY --from=distribution --chown=900:0 /distrib ${NUXEO_HOME}
COPY --from=source-build /build-output/nuxeo-source-ref.txt /usr/local/share/nuxeo-source-ref.txt
COPY --from=facets-bundle --chown=900:0 /build-output/content-lake-facets-bundle.jar ${NUXEO_HOME}/nxserver/bundles/content-lake-facets-bundle.jar
COPY --from=ui-overlay-bundle --chown=900:0 /build-output/content-lake-ui-bundle.jar ${NUXEO_HOME}/nxserver/bundles/content-lake-ui-bundle.jar
COPY --from=web-ui-build /build-output/nuxeo-web-ui-marketplace.zip /tmp/nuxeo-web-ui-marketplace.zip
COPY --from=web-ui-build /build-output/nuxeo-web-ui-version.txt /usr/local/share/nuxeo-web-ui-version.txt
COPY scripts/check-runtime-tools.sh /usr/local/bin/check-runtime-tools.sh

RUN chmod +x /docker-entrypoint.sh /install-packages.sh /nuxeo-run-dev.sh /usr/local/bin/check-runtime-tools.sh \
 && /usr/local/bin/check-runtime-tools.sh

RUN mkdir -p /etc/nuxeo \
 && printf 'nuxeo.home=%s\nnuxeo.data.dir=/var/lib/nuxeo\nnuxeo.log.dir=/var/log/nuxeo\nnuxeo.tmp.dir=/tmp\nJAVA_HOME=%s\n' \
      "${NUXEO_HOME}" "${JAVA_HOME}" > /etc/nuxeo/nuxeo.conf \
 && "${NUXEO_HOME}/bin/nuxeoctl" mp-install /tmp/nuxeo-web-ui-marketplace.zip \
      --accept=true --relax=true \
 && chown -R 900:0 "${NUXEO_HOME}" /etc/nuxeo /var/lib/nuxeo /var/log/nuxeo \
 && rm -f /tmp/nuxeo-web-ui-marketplace.zip /etc/nuxeo/nuxeo.conf

VOLUME /var/lib/nuxeo
VOLUME /var/log/nuxeo
VOLUME /tmp

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=10 \
  CMD wget -q -O /dev/null http://localhost:8080/nuxeo/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nuxeoctl", "console"]

USER 900
