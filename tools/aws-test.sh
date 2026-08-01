#!/bin/sh
# Run the full test suite (and, optionally, the benchmarks) on a real
# x86-64 Linux box in AWS — the correct tool for the one capability an
# arm64 Mac cannot host locally: MIR's JIT on x86.  A CPU emulator
# (Rosetta) runs the self-written x86 backend faithfully because that
# code is static (tools/x86-test.sh), but it cannot faithfully host a
# JIT that generates and runs code at run time; only the real ISA can.
#
#   tools/aws-test.sh           # launch, `zig build test`, tear down
#   tools/aws-test.sh bench     # also run bench/run.sh (real x86 timing)
#   tools/aws-test.sh keep      # leave the instance up (prints ssh line)
#
# It rsyncs the working tree (tracked + untracked, minus build/cache),
# so it tests exactly what is checked out — no need to commit or push
# first.  Everything it creates (key pair, security group, instance)
# is tagged luce-x86-ci and removed on exit, even on failure.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

mode="${1:-test}"
region="$(aws configure get region 2>/dev/null || echo us-east-1)"
tag=luce-x86-ci
itype=c7i.xlarge
ami="$(aws ssm get-parameter --region "$region" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)"
subnet="$(aws ec2 describe-subnets --region "$region" \
    --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
myip="$(curl -s https://checkip.amazonaws.com)"
work="$(mktemp -d)"
key_file="$work/key.pem"
zig_ver=0.16.0

instance=""
sg=""
key_name="$tag-$$"
cleanup() {
    set +e
    if [ "$mode" != keep ] || [ -z "$instance" ]; then
        [ -n "$instance" ] && aws ec2 terminate-instances --region "$region" \
            --instance-ids "$instance" >/dev/null 2>&1
        [ -n "$instance" ] && aws ec2 wait instance-terminated --region "$region" \
            --instance-ids "$instance" >/dev/null 2>&1
        [ -n "$sg" ] && aws ec2 delete-security-group --region "$region" \
            --group-id "$sg" >/dev/null 2>&1
        aws ec2 delete-key-pair --region "$region" --key-name "$key_name" >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT

echo "region=$region ami=$ami type=$itype"
aws ec2 create-key-pair --region "$region" --key-name "$key_name" \
    --query KeyMaterial --output text > "$key_file"
chmod 600 "$key_file"
sg="$(aws ec2 create-security-group --region "$region" \
    --group-name "$tag-$$" --description "luce x86 ci" \
    --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg" \
    --protocol tcp --port 22 --cidr "$myip/32" >/dev/null

echo "launching $itype ..."
instance="$(aws ec2 run-instances --region "$region" \
    --image-id "$ami" --instance-type "$itype" --key-name "$key_name" \
    --security-group-ids "$sg" --subnet-id "$subnet" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$tag}]" \
    --query 'Instances[0].InstanceId' --output text)"
aws ec2 wait instance-running --region "$region" --instance-ids "$instance"
ip="$(aws ec2 describe-instances --region "$region" --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
echo "instance $instance at $ip — waiting for ssh ..."

ssh_opts="-i $key_file -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
i=0
while [ $i -lt 40 ]; do
    if ssh $ssh_opts "ec2-user@$ip" true 2>/dev/null; then break; fi
    sleep 5; i=$((i + 1))
done

echo "installing zig $zig_ver ..."
ssh $ssh_opts "ec2-user@$ip" "set -e
    curl -fsSL https://ziglang.org/download/$zig_ver/zig-x86_64-linux-$zig_ver.tar.xz | tar -xJ
    sudo ln -sf \$PWD/zig-x86_64-linux-$zig_ver/zig /usr/local/bin/zig
    zig version"

echo "copying working tree ..."
# Tracked and untracked files, minus ignored ones (build/, .zig-cache).
git ls-files --cached --others --exclude-standard -z \
    | rsync -az --files-from=- --from0 -e "ssh $ssh_opts" ./ "ec2-user@$ip:luce/"

echo "=== zig build test (real x86-64, MIR + interpreter + zig backend) ==="
ssh $ssh_opts "ec2-user@$ip" "cd luce && zig build test" && test_ok=1 || test_ok=0

if [ "$mode" = bench ] && [ "$test_ok" = 1 ]; then
    echo "=== bench/run.sh (real x86-64 timing) ==="
    ssh $ssh_opts "ec2-user@$ip" "cd luce && ./build.sh >/dev/null 2>&1 && bench/run.sh"
fi

if [ "$mode" = keep ]; then
    echo "instance kept: ssh $ssh_opts ec2-user@$ip"
    echo "terminate with: aws ec2 terminate-instances --region $region --instance-ids $instance"
fi

[ "$test_ok" = 1 ] || { echo "TESTS FAILED on real x86-64"; exit 1; }
echo "real x86-64: all tests passed."
