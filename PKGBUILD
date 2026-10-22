# Maintainer: Magrid0 <Magrid0@proton.me>
#
# Advance currently ships without release tags, so this PKGBUILD builds from
# the master branch and derives a precise version from the checked-out commit.
# Once tagged releases exist, you can switch `source` to:
#   source=("$pkgname-$pkgver.tar.gz::$url/archive/v$pkgver.tar.gz")
# and drop pkgver().

pkgname=advance
pkgver=0.9.35
pkgrel=1
pkgdesc="Universal modular system update manager with priority groups and snapshot support"
arch=('any')
url="https://github.com/Stiggimy/advance"
license=('unknown')
depends=('bash' 'coreutils' 'findutils' 'gawk' 'grep' 'sed' 'iproute2' 'sudo')
makedepends=('git')
optdepends=(
    'fzf: interactive configuration and scheduling menus'
    'checkpoint: transactional pre/post update snapshots (https://github.com/Stiggimy/checkpoint)'
    'libnotify: desktop notifications for failures and background updates'
    'curl: import manager configurations from a URL'
    'pacman-contrib: checkupdates support for Pacman/Yay/Paru'
    'systemd: background auto-update timers'
)
install="$pkgname.install"
source=("$pkgname::git+$url.git#branch=master")
sha256sums=('SKIP')

pkgver() {
    cd "$pkgname"
    local ver
    ver=$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' advance | head -n 1)
    printf '%s.r%s.g%s' "${ver:-0.0.0}" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

package() {
    install -Dm755 "$pkgname/advance" "$pkgdir/usr/bin/advance"

    install -d "$pkgdir/usr/lib/advance"
    install -m644 "$pkgname"/lib/*.sh "$pkgdir/usr/lib/advance/"

    install -Dm644 "$pkgname/advance.1" "$pkgdir/usr/share/man/man1/advance.1"

    install -d "$pkgdir/usr/share/advance"
    cp -a "$pkgname/catalog" "$pkgdir/usr/share/advance/"

    install -Dm644 "$pkgname/README.md" "$pkgdir/usr/share/doc/$pkgname/README.md"
}
