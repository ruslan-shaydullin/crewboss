#!/usr/bin/env perl
# crewboss redact_secrets: stdin -> stdout, masking secret-shaped tokens so that
# any `set -x` / verbose / echo $TOKEN never lands in run.log. Belt-and-suspenders:
# explicit known env values + secret-shaped patterns.
use strict; use warnings;
$| = 1;
my @lits = grep { defined && length } ($ENV{CLAUDE_CODE_OAUTH_TOKEN}, $ENV{GH_TOKEN}, $ENV{ANTHROPIC_API_KEY});
while (my $line = <STDIN>) {
  for my $s (@lits) { $line =~ s/\Q$s\E/REDACTED-SECRET/g; }
  $line =~ s/sk-ant-[A-Za-z0-9_\-]{12,}/REDACTED-ANT/g;
  $line =~ s/gh[pousr]_[A-Za-z0-9]{16,}/REDACTED-GH/g;
  $line =~ s/github_pat_[A-Za-z0-9_]{20,}/REDACTED-GHPAT/g;
  $line =~ s/glpat-[A-Za-z0-9_\-]{16,}/REDACTED-GLPAT/g;
  $line =~ s/ya29\.[A-Za-z0-9_\-]+/REDACTED-GOOG/g;
  $line =~ s{x-access-token:[^@\s/]+\@}{x-access-token:REDACTED@}g;
  $line =~ s{https://[^:/@\s]+:[^@\s/]+\@}{https://REDACTED-CREDS\@}g;
  print $line;
}
