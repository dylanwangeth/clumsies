# Overview

## What clumsies is

clumsies is not another prompt folder and not just a thin registry wrapper. It treats prompts as organizational infrastructure: assets that can be distributed, referenced, traced, revised, and fed back into a shared system.

That framing matters because the project is not only about storing prompt text. It is about making prompt quality observable and improvable across teams.

## The project currently holds two realities at once

clumsies is easiest to understand when you accept that it spans two overlapping layers:

| Layer | What it means |
| --- | --- |
| Current runtime layer | local `.prompts/`, registry-era flows, MCP interfaces, and local trace already exist and can be used today |
| Emerging hub layer | Hub Server, Library, Workspace, proposal flow, and a TUI-first client define where the system is heading |

The docs keep these layers distinct on purpose. Without that split, the codebase feels contradictory even when it is actually following a migration path.

## What this site is trying to do

This site is not trying to dump every internal note into public view. It is trying to give the reader a stable first model:

| Section | Role |
| --- | --- |
| Overview | project shape and reading entry point |
| Concepts | stable definitions for the core objects |
| Architecture | current implementation versus target system shape |
| Guides and Reference | reading paths, repo map, and supporting material |

## Recommended reading order

1. Start with [Concepts](/concepts).
2. Continue to [Architecture](/architecture).
3. Use [Repo map](/repos) when you want to connect the model back to the codebase.
