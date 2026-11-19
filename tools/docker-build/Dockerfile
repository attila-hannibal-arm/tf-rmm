FROM ubuntu:24.04

WORKDIR /workspace

ENV RMM_SOURCE_DIR=/workspace/tf-rmm
ENV RMM_BUILD_DIR=/workspace/rmm-build

ENV PYENV_ROOT=/.pyenv
ENV TZ=Europe/Budapest
ENV DEBIAN_FRONTEND=noninteractive
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1


RUN apt update && apt install -y build-essential python3 python3-pip make ninja-build gcovr clang-tidy netcat-openbsd python3-venv telnet libreadline-dev cmake git valgrind gnuplot llvm llvm-dev lld

RUN git clone https://github.com/AFLplusplus/AFLplusplus.git && cd AFLplusplus && make distrib && make install

RUN mkdir -p /.cache/pip
RUN chmod -R 777 /.cache
RUN chmod 777 /workspace
COPY build.sh /workspace/build.sh

ENTRYPOINT [ "/workspace/build.sh" ]
