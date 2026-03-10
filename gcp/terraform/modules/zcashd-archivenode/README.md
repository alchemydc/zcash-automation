# zcashd-archivenode Terraform Module

## Variable: enable_cron_backups

- **Type:** bool
- **Default:** false

Controls whether backup cron jobs are scheduled on provisioned archive nodes.  
Set to `true` to enable automatic installation of backup cron jobs during provisioning.  
This variable is defined and set at the module level; it is not inherited from the project root.
