{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_SESSION_START_COMMAND_JSON__,
            "timeout": 15
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 3
          }
        ]
      }
    ],
    "StopFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_ISSUE_RUN_EVENT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
