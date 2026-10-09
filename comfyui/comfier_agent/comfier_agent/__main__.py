"""python -m comfier_agent [subcommand]: see comfier_agent.cli. With no subcommand it runs the agent."""

import sys

from comfier_agent.cli import main

if __name__ == "__main__":
    sys.exit(main())
