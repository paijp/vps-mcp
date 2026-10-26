#!/bin/bash
# https://github.com/paijp/vps-mcp
# certbot-deploy.sh: deploy hook called by certbot after successful renewal.
set -euo pipefail

systemctl reload nginx
