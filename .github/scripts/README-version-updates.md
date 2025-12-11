# Automated Discussion Template Version Updates

This directory contains automation for keeping RabbitMQ and Erlang versions up-to-date in the GitHub Discussions question template.

## Files

### `.github/versions.json`
Tracks current versions in JSON format. This file serves as the source of truth and makes it easy to detect changes.

### `.github/DISCUSSION_TEMPLATE/questions.yml.tpl`
YTT template for the discussion questions form. Uses `#@ for` loops to generate version dropdown options from `versions.json`.

### `.github/DISCUSSION_TEMPLATE/questions.yml`
Generated output file (do not edit directly - edit the `.tpl` file instead).

### `.github/scripts/update-versions.sh`
Bash script that:
1. Fetches latest RabbitMQ releases from GitHub API (stable 4.x releases only)
2. Fetches Erlang versions from `otp_versions.table` in erlang/otp repository
3. Filters to last 2 RabbitMQ minor versions (e.g., 4.2.x and 4.1.x)
4. Filters to last 3 Erlang major versions by minor (e.g., 28.x, 27.x, 26.x)
5. Updates `versions.json`
6. Uses `ytt` to render `questions.yml` from the template
7. Exits with status 0 if no changes, allowing workflow to skip PR creation

### `.github/workflows/update-discussion-versions.yml`
GitHub Actions workflow that:
- Installs `ytt` using carvel-dev/setup-action
- Runs weekly on Mondays at 9am UTC
- Can be manually triggered via workflow_dispatch
- Creates a PR only if versions changed
- Assigns PR to @lukebakken and @michaelklishin
- Uses `[skip ci]` prefix to avoid triggering CI on version-only changes

## Version Selection Logic

### RabbitMQ
- Fetches all stable releases (no pre-releases, drafts, or RCs)
- Groups by minor version (X.Y)
- Keeps all patch versions from the last 2 minor versions
- Example: If 4.3.0 is released, keeps all 4.3.x and 4.2.x, drops 4.1.x

### Erlang
- Parses `otp_versions.table` for version strings like `OTP-28.3`
- Formats as `X.Y.x` (e.g., `28.3.x`)
- Keeps one entry per minor version
- Includes last 3 major versions
- Example: 28.3.x, 28.2.x, 28.1.x, 28.0.x, 27.3.x, 27.2.x, etc.

## Testing

To test the script locally:

```bash
cd /path/to/rabbitmq-server
.github/scripts/update-versions.sh
```

The script will:
- Fetch latest versions
- Update both files
- Report if changes were detected
- Exit with status 0 (no changes) or continue (changes detected)

To test the full workflow without waiting for the cron schedule:
1. Go to Actions tab in GitHub
2. Select "Update Discussion Template Versions"
3. Click "Run workflow"

## Maintenance

The automation should require minimal maintenance. Potential future updates:

1. **Major version transition**: When RabbitMQ 5.x becomes the supported series, update the community support policy checkbox in `questions.yml` manually
2. **Version count changes**: If policy changes to support more/fewer versions, adjust the filtering logic in `update-versions.sh`
3. **Source changes**: If Erlang changes their version table location, update the curl URL

## Dependencies

- `gh` CLI tool (GitHub CLI) - for fetching releases
- `jq` - for JSON processing
- `curl` - for fetching Erlang versions
- Standard Unix tools: `cut`, `sort`, `grep`
