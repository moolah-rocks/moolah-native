# AI Review Gate Guide

This guide applies to every AI reviewer agent in this repo.

## Findings Are Fix Requests

Every finding is a fix request, not a discussion item. There is no "follow-up later", "defer", or "out of scope" tier in reviewer output.

Expected outcomes:

- The author fixes the issue before the work merges, commits, or tags a release, as applicable.
- The author rebuts the finding with a concrete technical reason, and the reviewer drops it.

Pre-existing problems are still findings. Do not qualify a finding with "this was already there" or "not introduced by this change". If the reviewer notices it, raise it at the same severity it would have if the current change introduced it.

If a finding is genuinely too large for the current change, stop and get explicit user authorization before deferring it. The default is to fix it now.

The only exception is scope the user has explicitly authorized in the conversation. Note that authorization in the review report.

After fixes, repeat the relevant review until it reports no findings.

## Fix the Whole Class, Not Just the Instance

When a finding identifies a root cause — a misused API, an unsafe pattern, a missing guard, a flaky-test shape — search the codebase for every other site with the same root cause and fix them all in the same change. Fixing only the flagged instance leaves the rest as latent bugs that resurface later in a different context, harder to diagnose because the link to the original fix is gone. List every site you fixed so the scope considered is visible.
