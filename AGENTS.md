# Notes for coding agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) first.

- This repository is public. Code, comments, docs and commit messages contain only technical and
  practical content about the code and features: what changed and its technical reason. Never write
  business or product reasoning, internal decisions or discussions, who asked for a change, review
  or audit reports, or names and paths of private repositories and internal tools.
- Run `scripts/test.sh` before every commit; it must pass.
- User-facing words follow [docs/voice.md](docs/voice.md).
- Never commit secrets, tokens, signing material (`*.cer`, `*.p12`, `*.certSigningRequest`) or
  personal paths.
