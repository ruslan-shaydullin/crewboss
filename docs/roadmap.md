# Contributor roadmap

The alpha work focuses on a reviewable installation, authenticated dashboard,
repeatable checks and a launcher that handles infrastructure failures honestly.
The runtime remains experimental. Start with the local demo before working on
live orchestration.

## Open contribution tracks

| Track | Issue | Scope |
| --- | --- | --- |
| First contribution | [#1349](https://github.com/ruslan-shaydullin/crewboss/issues/1349) | Offline links check for supported guides |
| Dashboard accessibility | [#1350](https://github.com/ruslan-shaydullin/crewboss/issues/1350) | Dialog keyboard focus and dismissal |
| Runtime architecture | [#1351](https://github.com/ruslan-shaydullin/crewboss/issues/1351) | Native Linux aarch64 sandbox policy and acceptance tests |
| Localization | [#314](https://github.com/ruslan-shaydullin/crewboss/issues/314) | Broader English/Russian UI coverage; keyboard slice tracked separately |
| UI performance | [#315](https://github.com/ruslan-shaydullin/crewboss/issues/315) | Component coverage and measured rendering improvements |

The CI wiring requested in #315 is already delivered by the open-source setup;
its other acceptance criteria remain open. Older issues can reference historical
paths, test counts and workflow job names. Check the current source and discuss
scope before beginning a large item.

The capability, replica and observer milestones (#354, #342, #341, #340) are
architectural work with existing dependency chains. They are not prerequisites for
trying the alpha demo and are not automatically scheduled by this release.

New contributor tickets deliberately omit launcher execution labels. Opening a
public issue should not spend an agent session. Maintainers can explicitly plan
runtime execution after a contributor's scope is agreed.
