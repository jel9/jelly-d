## JellyD

[![Run all D Tests](https://github.com/jel9/jelly-d/actions/workflows/test.yml/badge.svg)](https://github.com/jel9/jelly-d/actions/workflows/test.yml)

Bunch of D utilities and graphics related stuff.

### Modules

* `jelly.main`: shared components used in all modules
* `jelly.image`: various image formats
* `jelly.jni`: JNI bindings
* `jelly.window`: create windows on linux and windows, for use with OpenGL
* `jelly.config`: custom config format

_most of these are not done, might not work and so on_

## Goals

* Dont have any thirdparty dependencies (except JNI which is used by `jelly.jni`)
* Support only windows and linux
* Be simple and easy to use