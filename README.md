# IMDSv1 SSRF lab

One-command lab: SSRF against EC2 **IMDSv1**, steal the instance-role credentials, read a private S3 object, then require **IMDSv2** and watch the same request return 401.

**Throwaway account only. Port 80 is open to the world. Run `./destroy.sh` when you are done.**

```bash
git clone https://github.com/Pranav-Thorve/imdsv1-ssrf-lab.git
cd imdsv1-ssrf-lab
chmod +x setup.sh destroy.sh
./setup.sh
```

Needs AWS CLI v2 and credentials that can create EC2, IAM, and S3 in the default VPC (`AWS_REGION` defaults to `us-east-1`).

The script prints the public IP and the two browser URLs.

```bash
./destroy.sh
```
