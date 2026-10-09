"""Static syntax/configuration checks; not a replacement for Xcode compilation."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / '.tools'))
import yaml
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
errors = []
for folder in ['Pulse', 'PulseUITests', 'scripts']:
    for path in sorted((root / folder).rglob('*.swift')):
        source = path.read_bytes()
        tree = parser.parse(source)
        if tree.root_node.has_error:
            stack = [tree.root_node]
            while stack:
                node = stack.pop()
                if node.type == 'ERROR' or node.is_missing:
                    errors.append(f'{path.relative_to(root)}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}: {source[node.start_byte:node.end_byte].decode(errors="replace")[:160]}')
                else:
                    stack.extend(reversed(node.children))
        else:
            print(f'Syntax OK: {path.relative_to(root)}')
project = yaml.safe_load((root / 'project.yml').read_text())
workflow = yaml.safe_load((root / '.github/workflows/build-ios.yml').read_text())
assert project['schemes']['Pulse']['test']['targets'] == ['PulseUITests']
assert 'verify-ui' in workflow['jobs']
assert project['targets']['Pulse']['settings']['base']['CODE_SIGN_ENTITLEMENTS'] == 'Pulse/Pulse.entitlements'
for target in project['targets'].values():
    for folder in target['sources']:
        assert (root / folder).is_dir(), folder
assert (root / 'scripts/generate-icon.swift').is_file()
print('XcodeGen and workflow YAML: OK')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Static checks passed. Xcode compilation and device validation still required.')