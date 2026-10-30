import Foundation

/// A copy of a layout file that one icon collected many records in, with every app made up: the apps are `com.example.appNN`, and the
/// names that the apps gave nothing of are neutral ones. It is what the check of the saved icons is tested on: the file as it was (version 1),
/// what each app lists when it is read whole, and what the layout is expected to be after the check.
enum SittingFixture {
    /// The version 1 file, as it was written.
    static let version1File = #"""
{
  "document": {
    "activeProfileName": "Default",
    "profiles": [
      {
        "name": "Default",
        "sections": {
          "apps": {
            "com.example.app01": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app02": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app03": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app04": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app05": {
              "isAuto": true,
              "section": "hidden"
            },
            "com.example.app06": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app07": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app08": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app09": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app10": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app11": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app12": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app13": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app14": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app15": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app16": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app17": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app18": {
              "isAuto": false,
              "section": "alwaysHidden"
            },
            "com.example.app19": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app20": {
              "isAuto": true,
              "section": "hidden"
            },
            "com.example.app21": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app22": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app23": {
              "isAuto": true,
              "section": "hidden"
            },
            "com.example.app24": {
              "isAuto": false,
              "section": "hidden"
            },
            "com.example.app25": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app26": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app27": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app28": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.app29": {
              "isAuto": false,
              "section": "shown"
            },
            "com.example.mantel.testitem": {
              "isAuto": false,
              "section": "hidden"
            }
          },
          "groupItems": {},
          "groupOrder": [],
          "groups": {},
          "newItems": "shown",
          "order": {
            "alwaysHidden": [
              "com.example.app18#0",
              "com.example.app18::x.main-menu",
              "com.example.app18::mantel.dot.hidden",
              "com.example.app18::mantel.dot.always"
            ],
            "hidden": [
              "com.example.app04#0",
              "com.example.app15#0",
              "com.example.app06#0",
              "com.example.mantel.testitem::mantel.fixture.extra.12",
              "com.example.app11::mantel.dot.hidden",
              "com.example.mantel.testitem::mantel.fixture.extra.11",
              "com.example.mantel.testitem::mantel.fixture.extra.10",
              "com.example.mantel.testitem::mantel.fixture.extra.9",
              "com.example.app07::x.main-menu",
              "com.example.mantel.testitem::mantel.fixture.extra.8",
              "com.example.app07::mantel.fixture.two",
              "com.example.app07::mantel.fixture.extra.2",
              "com.example.app07::mantel.fixture.extra.1",
              "com.example.app08::x.main-menu",
              "com.example.mantel.testitem::mantel.fixture.extra.7",
              "com.example.app08::mantel.fixture.extra.2",
              "com.example.mantel.testitem::mantel.fixture.extra.6",
              "com.example.mantel.testitem::mantel.fixture.extra.5",
              "com.example.mantel.testitem::mantel.fixture.extra.4",
              "com.example.app24::mantel.fixture.one",
              "com.example.mantel.testitem::mantel.fixture.extra.2",
              "com.example.mantel.testitem::mantel.fixture.extra.1",
              "com.example.app24#0",
              "com.example.app11#0",
              "com.example.app07#0",
              "com.example.app08#2",
              "com.example.mantel.testitem#0",
              "com.example.mantel.testitem#1",
              "com.example.mantel.testitem::x.main-menu",
              "com.example.mantel.testitem#2",
              "com.example.mantel.testitem#3",
              "com.example.app05#0",
              "com.example.app05#1",
              "com.example.app05#2",
              "com.example.mantel.testitem::mantel.fixture.one",
              "com.example.mantel.testitem::mantel.fixture.two",
              "com.example.app07::mantel.fixture.one",
              "com.example.mantel.testitem::mantel.fixture.extra.3",
              "com.example.app20::mantel.fixture.one",
              "com.example.app08::mantel.fixture.one",
              "com.example.app23#0",
              "com.example.app08#0",
              "com.example.app07::mantel.dot.hidden",
              "com.example.app11::mantel.fixture.one",
              "com.example.app20#0",
              "com.example.app20::mantel.dot.hidden",
              "com.example.app08#1",
              "com.example.app23::mantel.fixture.two",
              "com.example.app23::mantel.fixture.one",
              "com.example.app23#1",
              "com.example.app23::x.main-menu",
              "com.example.app23::mantel.dot.always",
              "com.example.app23::mantel.dot.hidden"
            ],
            "shown": [
              "system:airdrop",
              "system:bluetooth",
              "system:sound",
              "system:battery",
              "system:controlcenter",
              "com.example.app19#0",
              "com.example.app27#0",
              "system:audiovideo",
              "com.example.app16#1",
              "com.example.app28#0",
              "system:clock",
              "com.example.app21#0",
              "com.example.app29#0",
              "com.example.app02#0",
              "com.example.app02#1",
              "com.example.app02#2",
              "com.example.app02#3",
              "com.example.app10#0",
              "com.example.app13#0",
              "com.example.app12#0",
              "com.example.app22#0",
              "com.example.app22::x.open-panel",
              "com.example.app03#0",
              "system:now-playing",
              "com.example.app14::x.update-alert",
              "com.example.app14::x.update-status",
              "com.example.app26#0",
              "com.example.app26#1",
              "com.example.app21::x.notch-activation",
              "com.example.app22::x.save-panel",
              "com.example.app01#0",
              "com.example.app01#1",
              "com.example.app09#0",
              "system:wifi",
              "com.example.app16::x.main-menu",
              "com.example.app17::mantel.fixture.extra.1",
              "com.example.app17#0",
              "com.example.app25#0",
              "com.example.app17::mantel.fixture.one",
              "com.example.app16#0",
              "com.example.app19::x.main-menu",
              "com.example.app25::x.main-menu",
              "com.example.app14#0"
            ]
          },
          "spacers": {},
          "systemItems": {
            "bluetooth": "shown",
            "clock": "shown",
            "wifi": "shown"
          }
        }
      }
    ]
  },
  "version": 1
}
"""#

    /// The icons each app lists in a whole read: the app's own names, and `#n` for the others, in the order they are on the bar.
    static let wholeReads: [String: [String]] = [
        "com.example.app04": [
            "com.example.app04#0",
        ],
        "com.example.app05": [
            "com.example.app05#0",
        ],
        "com.example.app06": [
            "com.example.app06#0",
        ],
        "com.example.app07": [
            "com.example.app07#0",
        ],
        "com.example.app08": [
            "com.example.app08#0",
            "com.example.app08#1",
            "com.example.app08#2",
        ],
        "com.example.app11": [
            "com.example.app11#0",
        ],
        "com.example.app14": [
            "com.example.app14#0",
        ],
        "com.example.app16": [
            "com.example.app16#0",
        ],
        "com.example.app17": [
            "com.example.app17#0",
        ],
        "com.example.app18": [
            "com.example.app18#0",
        ],
        "com.example.app19": [
            "com.example.app19#0",
        ],
        "com.example.app20": [
            "com.example.app20#0",
        ],
        "com.example.app23": [
            "com.example.app23#0",
        ],
        "com.example.app24": [
            "com.example.app24#0",
        ],
        "com.example.app25": [
            "com.example.app25#0",
        ],
        "com.example.mantel.testitem": [
            "com.example.mantel.testitem::mantel.fixture.one",
            "com.example.mantel.testitem::mantel.fixture.two",
            "com.example.mantel.testitem::mantel.fixture.extra.1",
            "com.example.mantel.testitem::mantel.fixture.extra.2",
            "com.example.mantel.testitem::mantel.fixture.extra.3",
            "com.example.mantel.testitem::mantel.fixture.extra.4",
            "com.example.mantel.testitem::mantel.fixture.extra.5",
            "com.example.mantel.testitem::mantel.fixture.extra.6",
            "com.example.mantel.testitem::mantel.fixture.extra.7",
            "com.example.mantel.testitem::mantel.fixture.extra.8",
            "com.example.mantel.testitem::mantel.fixture.extra.9",
            "com.example.mantel.testitem::mantel.fixture.extra.10",
            "com.example.mantel.testitem::mantel.fixture.extra.11",
            "com.example.mantel.testitem::mantel.fixture.extra.12",
        ],
    ]

    /// The apps that have no whole read: what their records say is believed, until they are read.
    static let appsNotRead: Set<String> = [
        "com.example.app01",
        "com.example.app02",
        "com.example.app03",
        "com.example.app09",
        "com.example.app10",
        "com.example.app12",
        "com.example.app13",
        "com.example.app15",
        "com.example.app21",
        "com.example.app22",
        "com.example.app26",
        "com.example.app27",
        "com.example.app28",
        "com.example.app29",
    ]

    /// What each section's list is after the check, in order.
    static let expectedShown: [String] = [
            "system:airdrop",
            "system:bluetooth",
            "system:sound",
            "system:battery",
            "system:controlcenter",
            "com.example.app19#0",
            "com.example.app27#0",
            "system:audiovideo",
            "com.example.app28#0",
            "system:clock",
            "com.example.app21#0",
            "com.example.app29#0",
            "com.example.app02#0",
            "com.example.app02#1",
            "com.example.app02#2",
            "com.example.app02#3",
            "com.example.app10#0",
            "com.example.app13#0",
            "com.example.app12#0",
            "com.example.app22#0",
            "com.example.app22::x.open-panel",
            "com.example.app03#0",
            "system:now-playing",
            "com.example.app26#0",
            "com.example.app26#1",
            "com.example.app21::x.notch-activation",
            "com.example.app22::x.save-panel",
            "com.example.app01#0",
            "com.example.app01#1",
            "com.example.app09#0",
            "system:wifi",
            "com.example.app17#0",
            "com.example.app25#0",
            "com.example.app16#0",
            "com.example.app14#0",
        ]
    static let expectedHidden: [String] = [
            "com.example.app04#0",
            "com.example.app15#0",
            "com.example.app06#0",
            "com.example.mantel.testitem::mantel.fixture.extra.12",
            "com.example.mantel.testitem::mantel.fixture.extra.11",
            "com.example.mantel.testitem::mantel.fixture.extra.10",
            "com.example.mantel.testitem::mantel.fixture.extra.9",
            "com.example.mantel.testitem::mantel.fixture.extra.8",
            "com.example.mantel.testitem::mantel.fixture.extra.7",
            "com.example.mantel.testitem::mantel.fixture.extra.6",
            "com.example.mantel.testitem::mantel.fixture.extra.5",
            "com.example.mantel.testitem::mantel.fixture.extra.4",
            "com.example.mantel.testitem::mantel.fixture.extra.2",
            "com.example.mantel.testitem::mantel.fixture.extra.1",
            "com.example.app24#0",
            "com.example.app11#0",
            "com.example.app07#0",
            "com.example.app08#2",
            "com.example.app05#0",
            "com.example.mantel.testitem::mantel.fixture.one",
            "com.example.mantel.testitem::mantel.fixture.two",
            "com.example.mantel.testitem::mantel.fixture.extra.3",
            "com.example.app23#0",
            "com.example.app08#0",
            "com.example.app20#0",
            "com.example.app08#1",
        ]
    static let expectedAlwaysHidden: [String] = [
            "com.example.app18#0",
        ]

    /// How many records the file has before, how many its migration takes out, how many the check takes out, and how many are left.
    static let recordsBefore = 100
    static let recordsDroppedByTheFile = 7
    static let recordsDroppedByTheCheck = 31
    static let recordsAfter = 62
}
