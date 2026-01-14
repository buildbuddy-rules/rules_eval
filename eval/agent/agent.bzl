"""eval_agent rule - defines a pluggable evaluation agent."""

load(":providers.bzl", "AgentInfo")

def _eval_agent_impl(ctx):
    """Implementation of eval_agent rule."""

    return [
        AgentInfo(
            name = ctx.attr.agent_name if ctx.attr.agent_name else ctx.label.name,
            version = ctx.attr.version,
            runner = ctx.executable.runner,
            runfiles = ctx.attr.runner[DefaultInfo].default_runfiles,
            supports_model_override = ctx.attr.supports_model_override,
            default_model = ctx.attr.default_model,
            environment_vars = ctx.attr.env,
        ),
        DefaultInfo(
            files = depset([ctx.executable.runner]),
            runfiles = ctx.attr.runner[DefaultInfo].default_runfiles.merge(
                ctx.runfiles(files = ctx.files.data),
            ),
        ),
    ]

eval_agent = rule(
    implementation = _eval_agent_impl,
    doc = "Defines an agent that can run evaluation tasks.",
    attrs = {
        "runner": attr.label(
            doc = "Executable that runs the agent. Must accept: --instruction <file> --workdir <dir> --output <dir> --timeout <secs> [--model <model>]",
            executable = True,
            cfg = "target",
            mandatory = True,
        ),
        "agent_name": attr.string(
            doc = "Agent name (defaults to target name).",
        ),
        "version": attr.string(
            doc = "Agent version.",
            default = "1.0.0",
        ),
        "data": attr.label_list(
            doc = "Data files required at runtime.",
            allow_files = True,
            default = [],
        ),
        "supports_model_override": attr.bool(
            doc = "Whether agent accepts --model flag.",
            default = True,
        ),
        "default_model": attr.string(
            doc = "Default model if not specified.",
            default = "",
        ),
        "env": attr.string_dict(
            doc = "Environment variables required by agent (values are defaults, empty means required).",
            default = {},
        ),
    },
)
