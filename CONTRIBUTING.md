# Contributing

This project is part of the **Content Lake** PoC ecosystem. Contributions are welcome.

## Before You Start

- Read the [README](README.md) to understand what this repo does and how it fits into the broader ecosystem.
- Check the open issues before starting new work.
- For significant changes, open an issue first to discuss the approach.

## Making Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes. Keep commits focused -- one logical change per commit.
3. Test your changes by running the smoke tests after the stack is up:
   ```bash
   docker compose up --build -d
   ./scripts/smoke-events.sh
   ./scripts/smoke-conversion.sh
   ./scripts/smoke-facets.sh
   ```
4. Open a pull request. Describe what changed and why.

## Commit Messages

Use the format: `type: short description`

Types: `feat`, `fix`, `docs`, `chore`, `test`

## Code of Conduct

Be respectful and constructive. This is a PoC project -- learning and experimentation are welcome.
