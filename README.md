# ParadoxLab CLI

ParadoxLab CLI is a coding and research assistant maintained by Anand Damdiyal.

Product website: [paradoxlab.in](https://paradoxlab.in).
GitHub releases: [Windows and Linux downloads](https://github.com/Damdiyal/paradox-cli/releases).

Download published assets from the Releases page. Each release includes
platform archives and SHA-256 checksums.

## Use

Extract the archive for your platform into a permanent folder. On Linux run
`./bin/paradox --help`; on Windows run `bin\paradox.cmd --help`.
The archives include their required runtime. Keep the extracted folders together.
Configure your own supported model provider and API key when prompted.

Supported release targets are Linux x64, Linux arm64, and Windows x64.
macOS releases are retired. Optional microphone features require an input device
and operating-system permission. Financial research features do not place trades.

For optional QQ bot setup and QR login connector installation, see [the QQ guide](docs/qqbot.md).

## GitHub automation

After the first release is published, run `paradox setup-github` in a GitHub
repository to install dispatch, assistant, issue triage, scheduled triage and
pull request review workflows. Set the `OPENAI_API_KEY` repository secret and
`PARADOX_MODEL` and `PARADOX_BASE_URL` repository variables to your provider.
The generated workflows call this repository's versioned reusable workflow,
install the checksum-verified CLI archive, and retain the assistant report as
a workflow artifact. They use read access and do not publish comments or push
changes. Scheduled triage runs on weekdays; adjust its cron to your needs.

The files under `examples/workflows` are templates: `setup-github` replaces
`__PARADOX_RELEASE_TAG__` with the published release tag before writing them.

## Updates and support

Use the [Releases page](https://github.com/Damdiyal/paradox-cli/releases) for
published versions and [Issues](https://github.com/Damdiyal/paradox-cli/issues)
for support. Keep API keys, settings, and personal conversations out of reports.

This repository contains public product documentation, installers, and release
verification automation. Development source, internal logs, and source history
are maintained privately. Release archives contain executable application code
and redistributable dependencies.

The project uses the standard Apache-2.0 license; no custom or separate
commercial license is added. See [LICENSE](LICENSE), [NOTICE](NOTICE), and the
component licenses and notices included with each release for applicable terms.
