Feature: It is possible to compile a program via the confserver

  Background:
    Given ramen must be in the path
    And a file testme.ramen with content
      """
      define f as yield "hello world" as greetings every 1s;
      """
    And a file children/child.ramen with content
      """
      define c as select greetings || "!" as warmer_greetings from ../../testme/f;
      """
    And ramen confserver --insecure 29341 is started
    And ramen compserver --confserver localhost:29341 is started
    And the environment variable USER is set to TESTER

  Scenario: Local file can be compiled via confserver
    When I run ramen with arguments compile --confserver localhost:29341 testme.ramen
    Then ramen must mention "compiled (TODO)"
    And ramen must exit gracefully

  Scenario: Relative parent resolution happens via the source tree (failure mode)
    When I run ramen with arguments compile --confserver localhost:29341 children/child.ramen
    Then ramen must mention "err:"Cannot find parent source testme""
    And ramen must fail gracefully

  Scenario: Relative parent resolution happens via the source tree (success)
    When I run ramen with arguments compile --confserver localhost:29341 testme.ramen
    And I run ramen with arguments compile --confserver localhost:29341 children/child.ramen
    Then ramen must mention "compiled (TODO)"
    And ramen must exit gracefully
