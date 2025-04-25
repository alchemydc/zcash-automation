# Active Context

## Current Work Focus

### Infrastructure Setup
- Modernizing bootstrap.sh for gcloud SDK compatibility
- Preparing for comprehensive script testing
- Improving infrastructure initialization workflow
- Enhancing deployment reliability and security

### Infrastructure Modules
1. **Zcashd Nodes**
   - Archive node module implementation ✓
   - Full node module implementation ✓
   - Private node module implementation ✓

2. **Zebra Nodes**
   - Archive node module implementation ✓
   - Disabled by default

### Core Components
- Terraform configurations established
- GCP integration configured
- Module structure defined
- Startup scripts implemented
- Updated for Debian 12 compatibility

## Recent Changes

### Deployment Improvements
- Added OpenTofu support alongside Terraform
- Improved error handling in bootstrap script
- Updated GCP environment variable documentation
- Fixed firewall rules for public P2P connections
- Modernized Zcash installation and systemd service
- Added security hardening to systemd service
- Updated logging to use structured format
- Removed deprecated rsyslog config (now using journald)
- Disabled zebrad-archivenode by default
- Updated startup script for Debian 12 compatibility
- Switched from static service account keys to short-lived tokens
- Added `serviceAccountTokenCreator` role requirement
- Simplified bucket IAM permissions to use `storage.admin`
- Enhanced error handling for credential initialization
- Improved logging and error messages
- Updated documentation with new role requirements
- Added `enable_cron_backups` variable (default: false) to zcashd-archivenode and zebrad-archivenode modules, with documentation in module and top-level READMEs
- Startup scripts now use Google Ops Agent for logging/monitoring, replacing Stackdriver and Fluentd agents
- **Fixed order-of-operations and IAM role assignment in bootstrap.sh; startup script logs now visible in GCP console**
- **Persistent disk sizing is now managed by a global `data_disk_size` variable at the project level (default 300G), passed to all node modules**

### Zebra Archivenode Module Modernization
- `zebrad-archivenode/startup.sh` updated to use Google Ops Agent, remove deprecated logging/rsyslog/logrotate config, and use a consistent log() function.
- Zebra build command in `startup.sh` updated to use a variable for the release tag and include `--release --features prometheus --bin zebrad`.
- `zebracargo` disk resource in `zebrad-archivenode/main.tf` renamed to `zebraparams`.
- `machine_type` variable reference in `zebrad-archivenode/main.tf` corrected.
- Global `zebra_release_tag` variable implemented and passed to the module.

## Next Steps

### Immediate Priority
1. **Test Zebrad Archivenode Deployment**
   - Deploy a zebrad-archivenode instance using the updated module.
   - Verify startup script execution and logging in GCP Log Viewer.
   - Confirm Zebra builds and starts successfully.

2. **Startup Script Error Fixes**
   - Review and fix errors in `gcp/terraform/modules/zcashd-archivenode/startup.sh`
   - Validate correct execution and logging after fixes
   - Zcashd archivenode now starts and syncs after GPG/repo fixes

3. **Persistent Disk Sizing Refactor**
   - `data_disk_size` is now a global project-level variable (default 300G)
   - All node modules require it from the root module
   - Refactor complete

4. **Bootstrap Script Testing**
   - Test environment preparation
   - Validation of new API enablement
   - Verification of IAM role assignments
   - State bucket configuration testing
   - Service account setup validation

5. **Archive Node Deployment & Logging Validation**
   - Deploy a zcash archive node ✓ (Terraform code now successfully launches an archivenode instance in GCP)
   - VPC network race condition resolved (explicit depends_on and resource references added)
   - Verify logs are visible in Stackdriver (via Google Ops Agent)
   - Logging now confirmed working in GCP console

### Short Term
1. **Testing & Validation**
   - Comprehensive module testing
   - Deployment validation
   - Performance benchmarking
   - Security assessment

2. **Documentation**
   - Usage guides
   - Configuration references
   - Deployment procedures
   - Troubleshooting guides

### Medium Term
1. **Feature Enhancements**
   - Additional node type support
   - Enhanced monitoring capabilities
   - Automated backup solutions
   - Performance optimizations

2. **Infrastructure Improvements**
   - High availability configurations
   - Disaster recovery planning
   - Cost optimization strategies
   - Security hardening

## Active Decisions

### Architecture Choices
1. **Module Structure**
   - Separate modules per node type for maintainability
   - Standardized interface across modules
   - Consistent resource naming conventions
   - Reusable component patterns

2. **Configuration Management**
   - Variable-driven configuration
   - Environment-specific settings
   - Centralized state management
   - Versioned infrastructure

### Implementation Preferences
1. **Resource Management**
   - Clear resource dependencies
   - Consistent tagging strategy
   - Standardized naming conventions
   - Modular resource organization

2. **Monitoring Setup**
   - Comprehensive logging
   - Performance metrics
   - Alert configurations
   - Dashboard templates

## Project Insights

### Key Learnings
1. **Infrastructure Design**
   - Modular approach benefits
   - Configuration standardization importance
   - Resource organization strategies
   - State management considerations

2. **Operational Patterns**
   - Deployment workflows
   - Monitoring requirements
   - Maintenance procedures
   - Security considerations

### Areas for Improvement
1. **Technical Debt**
   - Documentation updates needed
   - Testing coverage expansion
   - Performance optimization opportunities
   - Security enhancement possibilities

2. **Process Optimization**
   - Deployment automation
   - Monitoring refinement
   - Maintenance streamlining
   - Documentation improvement
