# AgentCore Serverless Patterns — staging

Staging repo for patterns being prepared for
[aws-samples/serverless-patterns](https://github.com/aws-samples/serverless-patterns).

Each folder here is self-contained and matches the layout that repo expects, so a
finished pattern is moved across as a directory with no edits.

## Patterns

| Folder | Status | Description |
| --- | --- | --- |
| `cloudfront-agentcore-gateway-terraform` | in progress | Put your own custom domain in front of an Amazon Bedrock AgentCore Gateway, with OAuth |

Planned, not started:

- multi-region failover for the same front door
- the front door with AgentCore Memory

## Why this repo exists

Two reasons. The upstream fork needs GitHub SSH set up, which is a separate task,
and patterns should be deployed and torn down several times against a real account
before a pull request is opened.

## Submitting upstream

Per upstream `PUBLISHING.md`:

1. Fork `aws-samples/serverless-patterns`, clone it, add `upstream` as a remote
2. Branch as `{username}-{feature|fix}-{description}`
3. Copy the pattern folder in, commit, push, open a pull request
4. Open a **separate issue** using the new-pattern template — the PR alone does not
   produce a page on serverlessland.com
