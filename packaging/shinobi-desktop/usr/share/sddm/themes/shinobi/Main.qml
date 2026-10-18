// Shinobi OS login screen (SDDM, Qt 6).
//
// One screen, one question: the wallpaper, the mark, the clock, the account, a password.
// It matches the lock screen (hyprlock) that the session shows afterwards, so locking
// and logging in look like the same place.
//
// Only QtQuick core is used: no QtQuick.Controls, no QtQuick.Effects, no graphical
// effects module. The greeter runs as the unprivileged `sddm` user on a minimal image,
// and a theme that needs an optional Qt module fails by showing nothing at all.
// The wallpaper is a pre-darkened JPEG bundled with the theme rather than a blur
// computed at runtime, for the same reason.
//
// What SDDM hands this file (context properties): `sddm` (login, power, signals),
// `userModel`, `sessionModel`, `keyboard` and `config` (theme.conf).
import QtQuick

Rectangle {
    id: root

    // Palette: the same one as the lock screen, the Plymouth splash and the bar.
    readonly property color base: "#0a101b"
    readonly property color text: "#cdd6f4"
    readonly property color muted: "#7f849c"
    readonly property color line: "#45475a"
    readonly property color accent: root.setting("accent", "#89b4fa")
    readonly property color danger: "#f38ba8"
    readonly property color warning: "#f9e2af"

    // Everything is sized from the screen's height, so a 4K panel is not a postage
    // stamp and a 1366x768 laptop is not clipped.
    readonly property real u: Math.max(0.8, Math.min(2.0, height / 800))

    readonly property string mono: "JetBrainsMono Nerd Font Mono"

    property bool failed: false
    property bool busy: false
    // A line of explanation that is not "wrong password": no session installed, or the
    // login service did not answer.
    property string notice: ""
    // How long a login may go unanswered before the field is given back. SDDM answers a
    // login with a signal, and for some failures it does not send one (it returns without
    // a word when it cannot start the session), which would leave the field disabled
    // for good. Long enough that a slow PAM stack is not cut off: a second login() sent
    // while the first is still running is dropped by the daemon as well.
    property int loginTimeout: 30000
    // For the test harness, which has no keyboard to type with.
    property alias passwordText: password.text
    property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0

    color: base

    // theme.conf, with a default for every key: a missing or empty setting must not be
    // able to blank the screen.
    function setting(key, fallback) {
        if (typeof config === "undefined" || config === null)
            return fallback
        var value = config[key]
        return (value !== undefined && value !== null && String(value).length > 0) ? String(value) : fallback
    }

    // The accounts, read out of the repeater below. A property rather than a lookup in a
    // function, so that what is shown updates once the model has filled in: the repeater
    // creates its items after the first bindings are evaluated.
    property var accounts: []
    readonly property string currentLogin: accounts.length > userIndex ? accounts[userIndex].login : userModel.lastUser
    readonly property string currentName: accounts.length > userIndex ? accounts[userIndex].display : userModel.lastUser

    function refreshAccounts() {
        var list = []
        for (var i = 0; i < users.count; i++) {
            var item = users.itemAt(i)
            if (item)
                list.push({ login: item.login, display: item.display })
        }
        accounts = list
    }

    function step(by) {
        if (userModel.count < 2 || busy)
            return
        userIndex = (userIndex + by + userModel.count) % userModel.count
        password.text = ""
        failed = false
    }

    function submit() {
        if (busy || password.text.length === 0)
            return
        // SDDM silently drops a login it cannot start (no session to start, no account),
        // and nothing would ever tell this screen: say so here instead.
        if (sessionModel.count < 1) {
            notice = "No desktop session is installed"
            return
        }
        if (currentLogin.length === 0) {
            notice = "There is no account to log in to"
            return
        }
        busy = true
        failed = false
        notice = ""
        sddm.login(currentLogin, password.text, sessionModel.lastIndex)
    }

    // Gives the field back if SDDM never answers.
    Timer {
        interval: root.loginTimeout
        running: root.busy
        onTriggered: {
            root.busy = false
            root.notice = "The login service did not answer"
            password.forceActiveFocus()
        }
    }

    // The account list, instantiated so its names can be read by index.
    Repeater {
        id: users
        model: userModel
        onItemAdded: root.refreshAccounts()
        onItemRemoved: root.refreshAccounts()
        delegate: Item {
            readonly property string login: model.name
            readonly property string display: (model.realName && model.realName.length > 0) ? model.realName : model.name
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.busy = false
            // Clear the field first and flag the failure after: editing the text clears
            // the flag (onTextChanged below), so the other order erased the red state in
            // the same instant it was set.
            password.text = ""
            root.failed = true
            password.forceActiveFocus()
            shake.restart()
        }
        function onLoginSucceeded() {
            root.failed = false
            root.notice = ""
        }
    }

    // --- wallpaper ------------------------------------------------------------------
    Image {
        anchors.fill: parent
        source: root.setting("background", "background.jpg")
        fillMode: Image.PreserveAspectCrop
        asynchronous: false
        smooth: true
    }

    // Calms the picture so the text is readable on any part of it, and darkens the
    // bottom where the power buttons sit.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.039, 0.063, 0.106, 0.55) }
            GradientStop { position: 0.55; color: Qt.rgba(0.039, 0.063, 0.106, 0.70) }
            GradientStop { position: 1.0; color: Qt.rgba(0.039, 0.063, 0.106, 0.88) }
        }
    }

    // --- clock ----------------------------------------------------------------------
    Column {
        id: clock
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 64 * root.u
        spacing: 6 * root.u

        property date now: new Date()

        Timer {
            interval: 1000
            repeat: true
            running: true
            onTriggered: clock.now = new Date()
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(clock.now, "HH:mm")
            color: root.text
            font.family: root.mono
            font.pixelSize: 56 * root.u
            font.weight: Font.Light
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(clock.now, "dddd, d MMMM").toUpperCase()
            color: root.muted
            font.family: root.mono
            font.pixelSize: 13 * root.u
            font.letterSpacing: 3 * root.u
        }
    }

    // --- the login form ---------------------------------------------------------------
    Column {
        id: form
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 40 * root.u
        spacing: 18 * root.u

        // The mark, on a dark disc so its dark parts read against the picture.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 112 * root.u
            height: width

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Qt.rgba(0.039, 0.063, 0.106, 0.78)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)
            }
            Image {
                anchors.centerIn: parent
                width: 88 * root.u
                height: width
                source: "logo.png"
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SHINOBI OS"
            color: root.accent
            font.family: root.mono
            font.pixelSize: 22 * root.u
            font.weight: Font.Medium
            font.letterSpacing: 7 * root.u
        }

        // Who is logging in. With more than one account the arrow keys (or a click)
        // choose; with one it is only a label.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(name.implicitWidth + 60 * root.u, 300 * root.u)
            height: 26 * root.u

            Text {
                id: name
                anchors.centerIn: parent
                text: root.currentName
                color: root.text
                font.family: root.mono
                font.pixelSize: 16 * root.u
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 300 * root.u)
            }
            Text {
                visible: userModel.count > 1
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                text: "‹"
                color: root.muted
                font.pixelSize: 26 * root.u
            }
            Text {
                visible: userModel.count > 1
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                text: "›"
                color: root.muted
                font.pixelSize: 26 * root.u
            }
            MouseArea {
                anchors.fill: parent
                enabled: userModel.count > 1
                cursorShape: userModel.count > 1 ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.step(1)
            }
        }

        // The password field.
        Item {
            id: field
            anchors.horizontalCenter: parent.horizontalCenter
            width: 320 * root.u
            height: 52 * root.u

            property real shift: 0

            Rectangle {
                id: box
                x: field.shift
                width: parent.width
                height: parent.height
                radius: 8 * root.u
                color: Qt.rgba(0.118, 0.118, 0.180, 0.86)
                border.width: 2
                border.color: root.failed ? root.danger : (password.activeFocus ? root.accent : root.line)

                Behavior on border.color { ColorAnimation { duration: 140 } }

                Text {
                    visible: password.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 20 * root.u
                    text: root.busy ? "signing in" : "password"
                    color: root.muted
                    font.family: root.mono
                    font.pixelSize: 17 * root.u
                    font.letterSpacing: 2 * root.u
                }

                TextInput {
                    id: password
                    anchors.fill: parent
                    anchors.leftMargin: 20 * root.u
                    anchors.rightMargin: 52 * root.u
                    verticalAlignment: TextInput.AlignVCenter
                    // A password longer than the field scrolls inside it; without the clip
                    // the dots are drawn outside the box.
                    clip: true
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    font.family: root.mono
                    font.pixelSize: 22 * root.u
                    font.letterSpacing: 4 * root.u
                    color: root.text
                    selectionColor: root.accent
                    selectedTextColor: root.base
                    cursorVisible: false
                    enabled: !root.busy
                    focus: true
                    // The password is never shown, never put in a tooltip or a hint, and
                    // not offered to an input method's predictive text.
                    inputMethodHints: Qt.ImhHiddenText | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | Qt.ImhSensitiveData

                    onTextChanged: {
                        root.failed = false
                        root.notice = ""
                    }

                    Keys.onReturnPressed: root.submit()
                    Keys.onEnterPressed: root.submit()
                    Keys.onEscapePressed: password.text = ""
                    Keys.onUpPressed: root.step(-1)
                    Keys.onDownPressed: root.step(1)
                }

                // Submit, for a pointer: the same as Enter.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    anchors.rightMargin: 8 * root.u
                    width: 36 * root.u
                    height: width
                    radius: 6 * root.u
                    color: submitArea.containsMouse && !root.busy ? Qt.rgba(0.537, 0.706, 0.980, 0.18) : "transparent"
                    opacity: password.text.length > 0 || root.busy ? 1.0 : 0.35

                    Text {
                        anchors.centerIn: parent
                        text: root.busy ? "…" : "→"
                        color: root.accent
                        font.family: root.mono
                        font.pixelSize: 22 * root.u
                    }
                    MouseArea {
                        id: submitArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.submit()
                    }
                }
            }

            SequentialAnimation {
                id: shake
                NumberAnimation { target: field; property: "shift"; to: -12 * root.u; duration: 50 }
                NumberAnimation { target: field; property: "shift"; to: 12 * root.u; duration: 80 }
                NumberAnimation { target: field; property: "shift"; to: -8 * root.u; duration: 70 }
                NumberAnimation { target: field; property: "shift"; to: 8 * root.u; duration: 60 }
                NumberAnimation { target: field; property: "shift"; to: 0; duration: 50 }
            }
        }

        // One line of status, always the same height so nothing jumps when it appears.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: field.width
            height: 20 * root.u

            Text {
                anchors.centerIn: parent
                text: root.failed ? "Authentication failed"
                    : (root.notice.length > 0 ? root.notice
                    : (keyboard && keyboard.capsLock ? "Caps Lock is on" : ""))
                color: (root.failed || root.notice.length > 0) ? root.danger : root.warning
                font.family: root.mono
                font.pixelSize: 13 * root.u
                font.letterSpacing: 1 * root.u
            }
        }
    }

    // --- power ----------------------------------------------------------------------
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 40 * root.u
        spacing: 36 * root.u

        Repeater {
            model: [
                { label: "SHUT DOWN", can: sddm.canPowerOff, act: 0 },
                { label: "RESTART", can: sddm.canReboot, act: 1 }
            ]
            delegate: Text {
                visible: modelData.can
                text: modelData.label
                color: powerArea.containsMouse ? root.accent : root.muted
                font.family: root.mono
                font.pixelSize: 12 * root.u
                font.letterSpacing: 3 * root.u

                MouseArea {
                    id: powerArea
                    anchors.fill: parent
                    anchors.margins: -10 * root.u
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: modelData.act === 0 ? sddm.powerOff() : sddm.reboot()
                }
            }
        }
    }

    Component.onCompleted: password.forceActiveFocus()
}
