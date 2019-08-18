# Oh My Zsh Pull Request triage action

This GitHub Action analyzes the changes of a Pull Request when a pull_request event is
generated with the action `opened` or `synchronize`.

It's a special form of the [labeler GitHub Action](https://github.com/actions/labeler) that
also looks at the commit diffs of the Pull Request to apply more labels.
