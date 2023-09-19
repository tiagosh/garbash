![Garbash](image.png)


  ## Garbash - AST interpreter

  An AST interpreter written in bash. It's optimized for the lowest performance, and to provide the highest joy to the developer.

  ### Install deps
  - brew install jq (or apt-get install jq)

  ### Run locally (needs bash >= 4)
  - bash garbash.sh sum.json
  - bash garbash.sh fib.json
  - bash garbash.sh combination.json

  ### Docker
  - bash build.sh
  - bash run.sh sum.json
  - bash run.sh fib.json
  - bash run.sh combination.json