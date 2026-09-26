# Physical-IoT verification evidence plan

The existing IoT model already supports state/environment/cascading conflict detection and bounded safety search. No home-specific fork is required.

Recommended next evidence work:
1. preserve the current counterexample versus unverified semantics as compatibility-sensitive behavior;
2. add a consumer-neutral verification receipt/digest value if downstream reproducibility needs it;
3. add regression fixtures for a composed light loop where individually sensible rules produce a reachable undesirable state;
4. add a safety-invariant fixture where an ordinary automation cannot override a modeled safety state;
5. benchmark bounded verification over realistic small-building rule sets;
6. keep all fixtures generic — no consumer/product names.

This plan does not add WoTEx as a dependency.
