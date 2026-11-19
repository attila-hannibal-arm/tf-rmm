<!--
SPDX-License-Identifier: BSD-3-Clause
SPDX-FileCopyrightText: Copyright TF-RMM Contributors.
-->

# RMM build script

## How to setup this script

### Create an env file in tf-rmm/tools/docker-build/.env and set
```bash
UID=<your numeric uid>
GID=<your numeric gid>
```

or you can run this one-liner:
```bash
 $ printf 'UID=%s\nGID=%s\n' "$(id -u)" "$(id -g)" > tf-rmm/tools/docker-build/.env
```

This configuration file will also accept the fuzzing timeout environment variables.

This runs from the workspace root and overwrites the existing tools/docker-build/.env file.

### Create your exports and aliases
In your .bashrc set
```bash
export RMM_BUILD_DIR=<your build directory>
export RMM_SOURCE_DIR=<your source directory>
alias rmmbuild="docker compose -f <path to your source directory>/tools/docker-build/compose.yaml run --rm --build rmm-builder"
```

If you are also running builds on your native machine, the `RMM_BUILD_DIR` has to be a different one, because it will use a different cmake configuration.

### Start a new session
Either by running a new `bash` instance or creating a new terminal window

## Usage
Now `rmmbuild` is invoking the build.sh script from the correct directory.

You can try it out by
```bash
 $ rmmbuild --help
```

```bash
 $ rmmbuild --debug --test
```

```bash
 $ rmmbuild --valgrind
```

```bash
 $ rmmbuild --fuzz-valgrind-selective
```
