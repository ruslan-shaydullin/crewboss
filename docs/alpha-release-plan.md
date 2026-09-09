# Alpha release delivery plan

This plan tracks the owner-authorized follow-up to PR #1348. The release remains
experimental, with explicitly tested environments and no production deployment.

- [x] Review and merge #1348; require contributor, browser and Linux CI on main and enable private vulnerability reporting.
- [x] Unify runtime configuration, remove personal defaults, parameterize agent/jail paths, and extend doctor preflight.
- [x] Enforce API authentication at the Python entrypoint, restrict CORS, and replace event-stream tokens in URLs.
- [x] Validate installation and the API → launcher → fixture-agent lifecycle on isolated Linux with real systemd, flock, and nsjail.
- [x] Complete reliability work from #1341 and #1346: distinguish infrastructure failures, confirm terminal writes, handle reviewer deliverables, and park blocked queue heads.
- [x] Split focused API/UI/runtime responsibilities and migrate required prototype/snapshot fixtures before removing obsolete copies.
- [x] Prepare a credential-free demo, tutorial/screenshots, versioned alpha archive/checksums/release notes, and triage contributor-friendly backlog work.

## Verification and release boundaries

Contributor CI runs without secrets. Real GitHub/agent mutations use only explicit
operator configuration; integration fixtures do not spend provider sessions.
Systemd and namespace behavior must be verified on Linux before claiming that
coverage. Tests must exercise shipped implementations rather than frozen copies.

Each implementation step records its checks and any unresolved limitations here
before an alpha release is tagged. Review/merge and repository settings changes
are authorized by the owner; no production runtime deployment is included.

## Verification checkpoint

- PR #1348 merged as `3b6e32f`; main requires all three CI jobs and private
  vulnerability reporting is enabled.
- Local contributor checks pass: 25 offline test files, 127 UI tests, TypeScript
  and production build, plus syntax and canonical manifest validation.
- Release/installer checks cover deterministic output, inventory integrity,
  tampered files, symlinks, explicit destination and non-overwrite behavior.
- Demo and production dashboard pass headless browser checks; screenshots are
  in `docs/images/`.
- Native Linux x86_64 installed-runtime acceptance passes in
  [CI run 34364586695](https://github.com/ruslan-shaydullin/crewboss/actions/runs/34364586695):
  nine checks cover installation, authentication, role editing, singleton/pause,
  jailed dispatch/delivery, isolation, kill switch, API restart and keepalive.
- The same run passes contributor and browser checks. Focused regressions cover
  28 launcher failure/delivery cases and 16 runtime portability cases. Actual
  nsjail checks also identified and corrected resource-limit overflow and the
  procfs configuration default; the sandbox policy was preserved.
- Published archives and their checksums are tracked in the
  [alpha release](https://github.com/ruslan-shaydullin/crewboss/releases/tag/v0.1.0-alpha.1).
  Publication uses the artifact from successful main CI after the release PR merges.
- Contributor tickets #1349–#1351 cover documentation links, dialog accessibility
  and separately validated aarch64 sandbox support.
