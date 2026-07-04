{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": __CLUMSIES_SESSION_START_COMMAND_JSON__,
            "timeout": 15,
            "statusMessage": "Loading clumsies context"
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
