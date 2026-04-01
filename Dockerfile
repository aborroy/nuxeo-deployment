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
      -T"${NUXEO_BUILD_THREADS}"

RUN mkdir -p /build-output \
 && cp server/nuxeo-server-tomcat/target/nuxeo-server-tomcat-*.zip /build-output/nuxeo-server-tomcat.zip \
 && cp .nuxeo-source-ref /build-output/nuxeo-source-ref.txt

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

FROM ${NUXEO_BUILD_IMAGE} AS web-ui-build

ARG NUXEO_WEBUI_GIT_REF
ARG NUXEO_WEBUI_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/web-ui

RUN curl -fsSL "https://github.com/nuxeo/nuxeo-web-ui/archive/${NUXEO_WEBUI_GIT_REF}.tar.gz" \
      -o /tmp/nuxeo-web-ui-source.tar.gz \
 && tar -xzf /tmp/nuxeo-web-ui-source.tar.gz --strip-components=1 \
 && rm /tmp/nuxeo-web-ui-source.tar.gz

# The nuxeo-web-ui pom declares nuxeo-parent:2025.12 (a release version behind auth).
# The source-build stage builds all Nuxeo artifacts at 2025.13-SNAPSHOT and installs them
# into the shared Maven cache (id=nuxeo-maven).  Patch the parent version to match.
RUN sed -i '/nuxeo-parent/{n;s|<version>2025\.12</version>|<version>2025.13-SNAPSHOT</version>|}' pom.xml

# Force ordering: source-build must complete (and populate the shared Maven cache) first.
COPY --from=source-build /build-output/nuxeo-source-ref.txt /tmp/nuxeo-source-ref.txt

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
 && cp plugin/web-ui/marketplace/target/nuxeo-web-ui-marketplace-${NUXEO_WEBUI_VERSION}.zip \
      /build-output/nuxeo-web-ui-marketplace.zip \
 && printf '%s\n' "${NUXEO_WEBUI_VERSION}" > /build-output/nuxeo-web-ui-version.txt

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
 && rm -rf /var/cache /var/tmp/*

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
COPY --from=web-ui-build /build-output/nuxeo-web-ui-marketplace.zip /tmp/nuxeo-web-ui-marketplace.zip
COPY --from=web-ui-build /build-output/nuxeo-web-ui-version.txt /usr/local/share/nuxeo-web-ui-version.txt
COPY scripts/check-runtime-tools.sh /usr/local/bin/check-runtime-tools.sh
COPY scripts/patch-web-ui-config.sh /docker-entrypoint-initnuxeo.d/patch-web-ui-config.sh

RUN chmod +x /docker-entrypoint.sh /install-packages.sh /nuxeo-run-dev.sh /usr/local/bin/check-runtime-tools.sh /docker-entrypoint-initnuxeo.d/patch-web-ui-config.sh \
 && /usr/local/bin/check-runtime-tools.sh

RUN mkdir -p /etc/nuxeo \
 && printf 'nuxeo.home=%s\nnuxeo.data.dir=/var/lib/nuxeo\nnuxeo.log.dir=/var/log/nuxeo\nnuxeo.tmp.dir=/tmp\n' \
      "${NUXEO_HOME}" > /etc/nuxeo/nuxeo.conf \
 && "${NUXEO_HOME}/bin/nuxeoctl" mp-install /tmp/nuxeo-web-ui-marketplace.zip \
      --accept=true --relax=true \
 && chown -R 900:0 "${NUXEO_HOME}" /etc/nuxeo /var/lib/nuxeo /var/log/nuxeo \
 && rm -f /tmp/nuxeo-web-ui-marketplace.zip /etc/nuxeo/nuxeo.conf

COPY --chown=900:0 ui/nuxeo-custom-bundle.html ${NUXEO_HOME}/nxserver/nuxeo.war/ui/nuxeo-custom-bundle.html
COPY --chown=900:0 ui/content-lake-folder-control.html ${NUXEO_HOME}/nxserver/nuxeo.war/ui/content-lake-folder-control.html

VOLUME /var/lib/nuxeo
VOLUME /var/log/nuxeo
VOLUME /tmp

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=10 \
  CMD wget -q -O /dev/null http://localhost:8080/nuxeo/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nuxeoctl", "console"]

USER 900
