{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_SESSION_START_COMMAND_JSON__,
            "timeout": 15
          }
        ]
      }
    ],
    "BeforeAgent": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_USER_PROMPT_SUBMIT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ],
    "AfterAgent": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_STOP_CHECK_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ]
  },
  "mcpServers": {
    "clumsies": {
      "command": "clumsies",
      "args": ["mcp", "serve"]
    }
  }
}