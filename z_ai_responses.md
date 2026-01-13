Stack 1: S3 Image Management

- Modular scripts with single purposes
- Discover existing state, update if required or start fresh
- Deploy secure S3 bucket for Splunk installer storage
- Manage installer versioning with hash validation or other method if required
- Update detection (newer installer available) - depends - rules no clear yet, though safest is always latest
- Can be triggered: automatically, manually, or by dependency check

Stack 2: Splunk Deployment

- Depends on Stack 1
- Calls S3 script to guarantee usable installer available
- If valid installer exists → deploy EC2 instance (note first check is s3 exists, then check if installer exists, then if possible determine if installer can be used or needs replacement, and if replaced, replace it, and if possile cerify installer is valid - like use checksum or similar - once that is done, it should be ok to start ec2 installation
- If not → S3 script handles whatever is needed to guarantee s3 bucket hosted image is available before starting deployment and if not reports why not
