#!/usr/bin/env python3
import os
import aws_cdk as cdk
from stacks.emerald_dream_stack import EmeraldDreamStack

app = cdk.App()
EmeraldDreamStack(
    app,
    "EmeraldDreamStack",
    env=cdk.Environment(
        account=os.environ.get("CDK_DEFAULT_ACCOUNT"),
        region=os.environ.get("CDK_DEFAULT_REGION", "us-east-1"),
    ),
)
app.synth()
