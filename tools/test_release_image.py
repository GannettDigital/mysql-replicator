import subprocess
import unittest
from unittest.mock import call, patch

from release_image import verify_help


ROOT_HELP = '''OVERVIEW: Replicate MySQL binlog events.

USAGE: mysql-replicator <subcommand>

OPTIONS:
  --help                  Show help information.

SUBCOMMANDS:
  run                     Capture and apply events.
  fetch                   Download binlogs.
  replay                  Apply local binlogs.
  ctl                     Control a running process.
  support-bundle          Collect diagnostic files.
  inspect                 Decode binlogs.
  inspect-relay           Read relay files.
  blackhole               Decode without application.
  skip                    Skip a GTID.
  recovery                Inspect or resolve a pending transaction.

  See 'mysql-replicator help <subcommand>' for detailed help.
'''

CONTROL_HELP = '''OVERVIEW: Control a running process.

USAGE: mysql-replicator ctl <subcommand>

SUBCOMMANDS:
  status                  Show process state.
  stop                    Request a graceful stop.
  reload                  Reload configuration.

  See 'mysql-replicator help ctl <subcommand>' for detailed help.
'''


class ReleaseHelpTests(unittest.TestCase):
    def test_checks_root_and_nested_help_through_the_same_image_command(self):
        executable = ['docker', 'run', '--rm', 'release-image']
        with patch('release_image.command', side_effect=[ROOT_HELP, CONTROL_HELP]) as command:
            verify_help(executable)
        self.assertEqual(command.call_args_list, [call(*executable, '--help'),
                                                  call(*executable, 'ctl', '--help')])

    def test_missing_command_cannot_be_replaced_by_a_word_in_the_description(self):
        for root, control, missing in (
            (ROOT_HELP.replace('  replay ', '  removed '), CONTROL_HELP, 'replay'),
            (ROOT_HELP, CONTROL_HELP.replace('  reload ', '  removed '), 'reload'),
            ('ctl status|stop|reload', CONTROL_HELP, 'ctl'),
        ):
            with self.subTest(missing=missing), patch('release_image.command',
                    side_effect=[missing + '\n' + root, missing + '\n' + control]):
                with self.assertRaisesRegex(ValueError, 'Missing commands.*' + missing):
                    verify_help(['binary'])

    def test_help_execution_failure_is_not_ignored(self):
        with patch('release_image.command', side_effect=subprocess.CalledProcessError(1, ['binary'])):
            with self.assertRaises(subprocess.CalledProcessError):
                verify_help(['binary'])
