"""
A Lambda that AgentCore Gateway exposes as an MCP tool.

The Gateway does NOT send an API-Gateway-shaped event. Its contract is:

  event    a flat map of the tool's inputSchema properties, nothing else.
           No "body", no "headers", no "requestContext".

  context  the tool name arrives out of band at
             context.client_context.custom["bedrockAgentCoreToolName"]
           in the form "<target_name>___<tool_name>".

That prefix is what catches people out. The Gateway always prepends the target
name, so comparing the raw value against "say_hello" never matches and every call
falls through to the unknown-tool branch. It has to be stripped.

The reads below are defensive on purpose. A plain `aws lambda invoke` carries no
client_context at all, and that is the first useful way to test this function —
before a Gateway exists to call it. If the tool is broken you want to find out
here, not three layers up through OAuth and an MCP client.
"""

import os

# The Gateway's separator between target name and tool name. Three underscores.
TOOL_DELIMITER = "___"


def _resolve_tool_name(context):
    """Return the bare tool name, or "" when invoked outside the Gateway.

    Chained getattr rather than direct attribute access: on a direct invoke
    client_context is None, and on some runtimes `custom` is absent even when
    client_context exists.
    """
    client_context = getattr(context, "client_context", None)
    custom = getattr(client_context, "custom", None) or {}
    qualified_name = custom.get("bedrockAgentCoreToolName", "")

    if TOOL_DELIMITER in qualified_name:
        # "helloLambda___say_hello" -> "say_hello"
        return qualified_name.split(TOOL_DELIMITER, 1)[1]

    # Either a direct invoke (empty) or an unprefixed name. Pass it through
    # unchanged rather than guessing.
    return qualified_name


def lambda_handler(event, context):
    tool_name = _resolve_tool_name(context)

    # "" means a direct invoke, outside the Gateway. Treat that as the single tool
    # this function owns so `aws lambda invoke` is a useful test on its own.
    if tool_name in ("say_hello", ""):
        # AWS_REGION is a reserved Lambda variable and is always populated. Read at
        # runtime rather than templated in by Terraform, so the answer cannot be
        # wrong about where the code actually ran.
        return {
            "message": "Hello from AWS Lambda in {}".format(
                os.environ.get("AWS_REGION", "unknown-region")
            )
        }

    # Return a value rather than raising. The Gateway needs parseable JSON back; an
    # exception surfaces as an opaque failure with nothing to diagnose.
    return {
        "error": "unknown tool",
        "requestedTool": tool_name,
        "supportedTools": ["say_hello"],
    }
