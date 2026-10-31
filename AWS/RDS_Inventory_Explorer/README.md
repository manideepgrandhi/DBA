# RDS Inventory Explorer - moved

This tool now lives in its own public repository, with full history:

**<https://github.com/manideepgrandhi/rds-inventory-explorer>**

Get it in AWS CloudShell:

```
# git clone (update with git pull --ff-only)
git clone https://github.com/manideepgrandhi/rds-inventory-explorer.git ~/rds-inventory-explorer
cd ~/rds-inventory-explorer

# or the release zip, checksum verified
curl -fsSLO https://github.com/manideepgrandhi/rds-inventory-explorer/releases/latest/download/rds-inventory-explorer.zip
curl -fsSLO https://github.com/manideepgrandhi/rds-inventory-explorer/releases/latest/download/rds-inventory-explorer.zip.sha256
sha256sum -c rds-inventory-explorer.zip.sha256 && unzip -oq rds-inventory-explorer.zip && cd rds-inventory-explorer
```

Version 2.0.0 adds the Insights tab. If you had `~/DBA/AWS/RDS_Inventory_Explorer`, switch to `~/rds-inventory-explorer`. Saved `--save-data` files from 1.2.0 still merge.
