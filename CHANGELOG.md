# Changelog

## [1.5.0](https://github.com/Einlanzerous/construct-server/compare/v1.4.1...v1.5.0) (2026-02-17)


### Features

* Accept trigger jobs from other repos ([408f466](https://github.com/Einlanzerous/construct-server/commit/408f466ebba889294af5ec501a1ef0e57a1765b2))

## [1.4.1](https://github.com/Einlanzerous/construct-server/compare/v1.4.0...v1.4.1) (2026-02-17)


### Bug Fixes

* workflow updates should trigger deploys to construct ([f325570](https://github.com/Einlanzerous/construct-server/commit/f325570e9b7dba94c843246f46e5b5601251673a))

## [1.4.0](https://github.com/Einlanzerous/construct-server/compare/v1.3.0...v1.4.0) (2026-02-17)


### Features

* Actually expose services and show links via homer ([822a844](https://github.com/Einlanzerous/construct-server/commit/822a8442f2b2be7c5da94fa98bd8ebbb924a3cfa))
* New services added (vox-loop, cook-book), docker network, postgres, and some text updates ([db1f8a7](https://github.com/Einlanzerous/construct-server/commit/db1f8a703d45600c5a0ba42daa58691e00f434e6))
* Support signing into ghcr via ansible ([94787dd](https://github.com/Einlanzerous/construct-server/commit/94787dd8d5c20af58447cf6f5ed0032aa6a3128b))


### Bug Fixes

* Ensure docker network created before docker up ([4b6870d](https://github.com/Einlanzerous/construct-server/commit/4b6870d52a03411aabad4855135afde2ca4be1d5))
* Use github variable single file for secrets ([d69824f](https://github.com/Einlanzerous/construct-server/commit/d69824fea4f2a0137e06f2dcb37c804da31caf02))

## [1.3.0](https://github.com/Einlanzerous/construct-server/compare/v1.2.1...v1.3.0) (2026-02-02)


### Features

* support work laptop ([749a373](https://github.com/Einlanzerous/construct-server/commit/749a373a44d75a0d6c7f5dbd95c5bd1e9b0fc0ef))


### Bug Fixes

* address error on archive command ([f8bc55e](https://github.com/Einlanzerous/construct-server/commit/f8bc55ef9768d3eb735f8943e26120839639dcc1))
* Better handle errors on cli install ([5b68cfa](https://github.com/Einlanzerous/construct-server/commit/5b68cfa6678134609ee6a9318776e92e8ea26516))

## [1.2.1](https://github.com/Einlanzerous/construct-server/compare/v1.2.0...v1.2.1) (2025-12-26)


### Bug Fixes

* Ensure node is at least version 24 ([754138b](https://github.com/Einlanzerous/construct-server/commit/754138b85ed9de91ebe8c0d2b706b569ed996b19))

## [1.2.0](https://github.com/Einlanzerous/construct-server/compare/v1.1.3...v1.2.0) (2025-12-20)


### Features

* Add steam big picture mode to server ([16c9bbd](https://github.com/Einlanzerous/construct-server/commit/16c9bbdf4c0eeb7bc553cf6086d5ffe7dd469930))


### Bug Fixes

* Server should not have power saving when it has a fake monitor connected ([15bf0d7](https://github.com/Einlanzerous/construct-server/commit/15bf0d7de32a3300988d70e4e40c01e2b5f0a1a2))

## [1.1.3](https://github.com/Einlanzerous/construct-server/compare/v1.1.2...v1.1.3) (2025-12-20)


### Bug Fixes

* Add render group ([866b5d3](https://github.com/Einlanzerous/construct-server/commit/866b5d31759d5f40573627d5fe7ca60062dad192))
* Add Xorg to run on nvidia with customEDID, ensure neccessary components are installed ([e169cc0](https://github.com/Einlanzerous/construct-server/commit/e169cc0362dc783fba944f07f0d45a9861adaca6))
* Address ansible script ability to generate edid ([04b5a83](https://github.com/Einlanzerous/construct-server/commit/04b5a83a80bff44dcc182bd95b53c6f788b1e478))
* Address permissions errors, set wayland var, and have systemd user daemon reload ([6112358](https://github.com/Einlanzerous/construct-server/commit/6112358569af8ac29730f37df3971184795d4b0d))
* small errors need to be fixed ([b826280](https://github.com/Einlanzerous/construct-server/commit/b826280b68816b1546cee582605497f6c9fcb448))
* Verified sunshine boots up and appears to work correctly ([41a517b](https://github.com/Einlanzerous/construct-server/commit/41a517be129d3a6d9e15f4c38bfb3ce11ad91c14))

## [1.1.2](https://github.com/Einlanzerous/construct-server/compare/v1.1.1...v1.1.2) (2025-12-19)


### Bug Fixes

* Add ansible task for semaphore commands ([8ddc7ef](https://github.com/Einlanzerous/construct-server/commit/8ddc7efab2dddf8b715d5a167a54e74b19b52b5d))
* Address typo in config around DB for semaphore ([73e8b06](https://github.com/Einlanzerous/construct-server/commit/73e8b065043f924c5060fb53f4a4f6fbf14df4e3))

## [1.1.1](https://github.com/Einlanzerous/construct-server/compare/v1.1.0...v1.1.1) (2025-12-19)


### Bug Fixes

* Fix volume issue in docker-compose ([a50f2be](https://github.com/Einlanzerous/construct-server/commit/a50f2be7b502964467a15a50895976382f1e3683))

## [1.1.0](https://github.com/Einlanzerous/construct-server/compare/v1.0.1...v1.1.0) (2025-12-19)


### Features

* Add Semaphore UI, and clean up some of the homer dashboard view ([28762c0](https://github.com/Einlanzerous/construct-server/commit/28762c052f563c2d452bb326676519e360e6cf10))


### Bug Fixes

* Additional capabilities errors ([4e34fb1](https://github.com/Einlanzerous/construct-server/commit/4e34fb187ec9854df69aec202941be478f46e269))
* Address Sunshine user session ([e538faa](https://github.com/Einlanzerous/construct-server/commit/e538faae1ff8785f9413ffda247d94f13d25010c))
* Update tags to enable faster ansible processing for sunshine tag, tasks successfully running now ([2832471](https://github.com/Einlanzerous/construct-server/commit/283247155a29e174928ff6e49de80a761ecf2865))

## [1.0.1](https://github.com/Einlanzerous/construct-server/compare/v1.0.0...v1.0.1) (2025-12-19)


### Bug Fixes

* Address serverside sunshine error ([4b7aac0](https://github.com/Einlanzerous/construct-server/commit/4b7aac0db59be5ee23c849c32b84112e1470b59e))

## 1.0.0 (2025-12-19)


### ⚠ BREAKING CHANGES

* migrate secrets to sops and add sunshine streaming support

### Features

* migrate secrets to sops and add sunshine streaming support ([934f462](https://github.com/Einlanzerous/construct-server/commit/934f462bc60551e3ead2b8b9887d865b44c7734f))
