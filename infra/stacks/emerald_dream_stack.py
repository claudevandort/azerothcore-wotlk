import os
from aws_cdk import (
    Stack,
    CfnOutput,
    aws_ec2 as ec2,
    aws_iam as iam,
)
from constructs import Construct


class EmeraldDreamStack(Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        admin_ip = self.node.try_get_context("admin_ip")

        # Simple public-only VPC (no NAT gateway needed for a game server)
        vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=2,
            nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="Public",
                    subnet_type=ec2.SubnetType.PUBLIC,
                )
            ],
        )

        # Security Group
        sg = ec2.SecurityGroup(
            self,
            "WowServerSG",
            vpc=vpc,
            description="Emerald Dream WoW server",
            allow_all_outbound=True,
        )

        # Auth server — open to all players
        sg.add_ingress_rule(
            ec2.Peer.any_ipv4(),
            ec2.Port.tcp(3724),
            "WoW Auth Server",
        )

        # World server — open to all players
        sg.add_ingress_rule(
            ec2.Peer.any_ipv4(),
            ec2.Port.tcp(8085),
            "WoW World Server",
        )

        # SOAP — admin only
        if admin_ip:
            sg.add_ingress_rule(
                ec2.Peer.ipv4(admin_ip),
                ec2.Port.tcp(7878),
                "SOAP Admin",
            )

        # IAM role for SSM
        role = iam.Role(
            self,
            "WowServerRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name(
                    "AmazonSSMManagedInstanceCore"
                ),
            ],
        )

        # Ubuntu 22.04 AMI
        ubuntu_ami = ec2.MachineImage.generic_linux(
            ami_map={
                "us-east-1": "ami-0f9de6e2d2f067fca",  # Ubuntu 22.04 LTS us-east-1
            }
        )

        # Read user data script
        infra_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(infra_dir, "user_data", "setup.sh"), "r") as f:
            user_data_script = f.read()

        # EC2 Instance
        instance = ec2.Instance(
            self,
            "WowServer",
            instance_type=ec2.InstanceType("t3.large"),
            machine_image=ubuntu_ami,
            vpc=vpc,
            security_group=sg,
            role=role,
            block_devices=[
                ec2.BlockDevice(
                    device_name="/dev/sda1",
                    volume=ec2.BlockDeviceVolume.ebs(
                        50,
                        volume_type=ec2.EbsDeviceVolumeType.GP3,
                        delete_on_termination=False,
                    ),
                )
            ],
            user_data=ec2.UserData.custom(user_data_script),
            require_imdsv2=True,
        )

        # Elastic IP
        eip = ec2.CfnEIP(self, "WowServerEIP")
        ec2.CfnEIPAssociation(
            self,
            "WowServerEIPAssoc",
            eip=eip.ref,
            instance_id=instance.instance_id,
        )

        # Outputs
        CfnOutput(self, "InstanceId", value=instance.instance_id)
        CfnOutput(self, "ServerIP", value=eip.ref)
        CfnOutput(
            self,
            "SSMConnect",
            value=f"aws ssm start-session --target {instance.instance_id} --region us-east-1",
        )
        CfnOutput(
            self,
            "RealmlistWTF",
            value=f"set realmlist {eip.ref}",
            description="Put this in your WoW client realmlist.wtf",
        )
