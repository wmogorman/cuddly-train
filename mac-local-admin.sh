#!/bin/bash

USERNAME="dtxladmin"
PASSWORD="REPLACE_WITH_PASSWORD"
FULLNAME="Datamax Local Admin"

# Create user
sysadminctl -addUser $USERNAME -fullName "$FULLNAME" -password $PASSWORD

# Add to admin group
dseditgroup -o edit -a $USERNAME -t user admin

# Hide user from login screen
defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add $USERNAME

echo "Local admin created"