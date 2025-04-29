# Using GCP log based metrics to track sync and Performance

The following log-based metric works to get height from zebra log output.

Metric type: distribution
Filter selection: project logs
filter:
```
logName="projects/${var.project}/logs/syslog"
resource.type="gce_instance"
jsonPayload.message:"zebrad::components::sync::progress:"
jsonPayload.message:"current_height=Height("
```

field name: jsonPayload.message
regex: `current_height=Height\((\d+)\)`

can be visualized in a line chart dashboard using mean aggregation.

This metric is now managed via Terraform and applies to all Zebra nodes, supporting per-instance graphing.
