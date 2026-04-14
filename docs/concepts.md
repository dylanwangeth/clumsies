# Concepts

## Prompt

A Prompt is a behavioral instruction for an agent. It answers the question: how should the agent act?

In clumsies, prompts are usually grouped into two major forms:

| Type | Meaning |
| --- | --- |
| Rule | an individual constraint or policy |
| Workflow | an ordered set of constraints that implies execution flow |

Prompt is not the same thing as project knowledge. It tells the agent what to do, not what the project is.

## Context

Context is project reality. It answers the question: what is this project, why is it shaped this way, and what do we currently know?

Specs, ADRs, research notes, and journals are all forms of context. They give the agent evidence and background, but they do not directly impose behavior.

## Library

Library is the organization-level source of prompts. It is not a cache and not a loose pile of copies.

Once Library stops being authoritative, cross-workspace convergence becomes fragile. Prompt history, trace aggregation, and proposal flow all become harder to trust.

## Workspace

Workspace is the project boundary where prompts and context are combined for real work.

It binds together:

- the subset of prompts selected from Library
- the project-specific context that makes those prompts usable in a real codebase

That is why Workspace is not just a folder and not simply a git repository. It is a collaboration boundary around a concrete project.

## Trace

Trace is the structured event stream produced when prompts are loaded, cited, applied, or revised during real agent work.

Trace is not decorative analytics. It is the feedback signal for the prompt lifecycle. Without it, teams are left guessing which constraints actually mattered.

## Override

Override, or local edit, is a workspace-level deviation from a library prompt.

Its value is not that it allows random forks. Its value is that a team can test an adjustment inside a project first, then decide whether it deserves to flow back into the shared library.
