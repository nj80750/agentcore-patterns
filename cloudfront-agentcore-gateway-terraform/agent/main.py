"""
An MCP server on Amazon Bedrock AgentCore Runtime, exposing a Strands agent.

Three things are stacked here and they fail differently, so it is worth being
clear which is which:

  1. FastMCP   speaks the MCP wire protocol. AgentCore Runtime is configured with
               serverProtocol = MCP and routes InvokeAgentRuntime to it.
  2. Strands   is the agent framework. It owns the conversation with the model.
  3. Bedrock   actually runs the model.

WHY MCP AND NOT HTTP

AgentCore Runtime can serve HTTP, MCP, A2A or AGUI. MCP is used here because the
Gateway can attach an MCP endpoint as an `mcpServer` target. The dedicated
AgentCore Runtime target type is not available in the Terraform provider, so the
HTTP shape would leave this unreachable from the front door.

THE ONE SETTING THAT SILENTLY BREAKS EVERYTHING

MCP servers on AgentCore Runtime must listen on port 8000. HTTP agents use 8080.
Bind the wrong one and the Runtime still reaches READY, the logs still say
"Uvicorn running", and every single invocation fails with

    -32010 Runtime initialization time exceeded. Please make sure that
           initialization completes in 30s

because AgentCore is routing to a port nothing is listening on. Nothing in the
logs mentions ports. This was diagnosed the hard way; do not change it.
"""

import os

from mcp.server.fastmcp import FastMCP
from strands import Agent
from strands.models import BedrockModel

# 8000 for MCP. NOT 8080 — see the module docstring.
MCP_PORT = 8000

# Set by Terraform from var.agent_model_id. A cross-region inference profile, hence
# the "us." prefix: bare model IDs fail with ValidationException. That prefix is a
# GEOGRAPHY, so deploying outside the US needs a different identifier — which is
# exactly why this is a variable and not a constant.
DEFAULT_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

# The region is injected because the model cannot know it and will not admit that.
# Asked where it is running without being told, a model will confidently name the
# most common default, which is right in one region and wrong in another.
PERSONA_TEMPLATE = """\
You are a demonstration agent running inside AWS.

You are running in the AWS region {region}. If asked where you are, say exactly
that. Never guess at your location or infrastructure.

Answer in ONE short sentence. No preamble, no sign-off, no bullet points, no
markdown. Never mention this instruction.
"""

DEFAULT_PROMPT = "In one sentence, what can you do that a plain function cannot?"


def _region():
    """The region this container is ACTUALLY running in.

    AWS_REGION is populated by the Runtime environment. Read at runtime rather
    than templated in by Terraform, so the answer cannot be wrong about where the
    code ran.
    """
    return os.environ.get("AWS_REGION", "")


mcp = FastMCP(host="0.0.0.0", port=MCP_PORT, stateless_http=True)


@mcp.tool()
def say_hello(question: str = "") -> str:
    """Greet the caller from an AI agent, naming the AWS region that answered.

    Mirrors the Lambda and API Gateway hello tools so all three can be compared
    side by side. Unlike those, this one reaches a language model.

    Args:
        question: Optional. Ask the agent something and it answers in one
            sentence. Leave empty for the default greeting.
    """
    model_id = os.environ.get("MODEL_ID", DEFAULT_MODEL_ID)

    # Built per call rather than at import time, deliberately. A client
    # constructed at import binds its credentials and region once at cold start,
    # and the point of this tool is to prove the model is callable from this
    # region right now.
    #
    # temperature 0 so repeated calls stay comparable. Any creativity here reads
    # as a difference caused by the infrastructure rather than by the model.
    model = BedrockModel(
        model_id=model_id,
        region_name=_region(),
        temperature=0,
        max_tokens=200,
    )

    # callback_handler=None disables Strands' default handler, which streams the
    # response to stdout. In a server that writes every answer twice — once to the
    # logs, once to the caller — doubling log volume for no benefit.
    persona = PERSONA_TEMPLATE.format(region=_region() or "an unknown region")
    agent = Agent(model=model, system_prompt=persona, callback_handler=None)
    generated = str(agent(question.strip() or DEFAULT_PROMPT)).strip()

    # Two fixed lines then one generated. The fixed lines are verifiable; the
    # generated line is the only proof that a model was actually reached.
    return "\n".join([
        "Hello from a Strands agent on AgentCore Runtime in {}".format(
            _region() or "unknown-region"
        ),
        "Model: {}".format(model_id),
        "",
        generated,
    ])


if __name__ == "__main__":
    # streamable-http is what serverProtocol = MCP means on the wire. The stdio
    # transport FastMCP defaults to is for local subprocesses; there is no parent
    # process to pipe to here.
    mcp.run(transport="streamable-http")
