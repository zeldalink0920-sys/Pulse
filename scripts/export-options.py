import plistlib
import sys

team, profile, destination = sys.argv[1:]
with open(destination, 'wb') as output:
    plistlib.dump({
        'method': 'release-testing',
        'teamID': team,
        'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {'com.pulse.personal': profile},
        'stripSwiftSymbols': True,
    }, output)
