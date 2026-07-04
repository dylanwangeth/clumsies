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
            "command": __CLUMSIES_USER_PROMPT_SUBMIT_COMMAND_JSON__,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
