# Product Context

## Purpose
The Zcash Automation project provides infrastructure tooling to streamline the deployment and management of Zcash nodes in Google Cloud Platform (GCP). This tooling enables DevOps teams to efficiently manage both Zcashd and Zebra node infrastructure at scale.

## Problems Solved
1. Manual node deployment complexity
   - Eliminates error-prone manual configuration
   - Standardizes deployment processes
   - Reduces time-to-deployment for new nodes

2. Infrastructure management overhead
   - Automates resource provisioning
   - Provides consistent configuration across nodes
   - Simplifies scaling operations

3. Monitoring challenges
   - Integrates with GCP Stackdriver for unified monitoring
   - Enables centralized logging
   - Facilitates proactive maintenance

## How It Works
The project leverages Infrastructure as Code (IaC) principles through Terraform/OpenTofu to:
1. Create and configure various types of Zcash nodes (full, archive, private)
2. Set up monitoring and logging infrastructure
3. Manage cloud resources efficiently
4. Enable reproducible deployments

## User Experience Goals
1. Simplicity
   - Clear, documented deployment processes
   - Standardized configuration patterns
   - Minimal manual intervention required

2. Reliability
   - Consistent node deployments
   - Robust monitoring setup
   - Dependable infrastructure management

3. Flexibility
   - Support for different node types
   - Customizable configurations
   - Scalable architecture

4. Maintainability
   - Well-documented codebase
   - Modular design
   - Clear operational procedures
