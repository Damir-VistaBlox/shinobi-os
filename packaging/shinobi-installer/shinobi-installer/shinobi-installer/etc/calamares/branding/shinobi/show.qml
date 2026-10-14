/* The wizard's slideshow.
 *
 * Text only, deliberately. Slides with images need artwork produced and then
 * verified to look right inside a fixed-size frame, and a missing or cropped
 * image is worse on a welcome screen than no image at all. The wizard has about
 * a minute of this before anybody clicks anything, so the words carry the claims.
 *
 * What these slides are for is worth being plain about: this installs the same
 * system that is running, offline, from the medium in front of the operator. The
 * characteristic failure of a graphical installer is that it appears to know
 * more than it does, so each slide says something the operator can check
 * afterwards.
 *
 * The layout is an inline component with two properties rather than a set of
 * nested `id`s. Referring to a nested item's `id` from the slide instances is not
 * valid QML -- the ids are out of scope there -- and Calamares reported it as
 * "Cannot assign to non-existent property" on the welcome screen, which is the
 * one screen nobody would want to be broken.
 *
 * Part of Calamares: the framework is GPL-3.0-or-later and this file is a
 * configuration of it, licensed the same way.
 */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Timer {
        interval: 14000
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    // One slide's layout, defined once. Seven slides differ only in words, so a
    // change to the layout happens in one place.
    component ShinobiSlide: Slide {
        id: slide
        property string headingText: ""
        property string bodyText: ""

        Column {
            anchors.centerIn: parent
            width: slide.width
            spacing: 20

            Text {
                text: slide.headingText
                anchors.horizontalCenter: parent.horizontalCenter
                color: "#e6e9f5"
                font.pointSize: 19
                font.bold: true
                width: 560
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                text: slide.bodyText
                anchors.horizontalCenter: parent.horizontalCenter
                color: "#a6adc8"
                font.pointSize: 11
                width: 580
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.RichText
            }
        }
    }

    ShinobiSlide {
        headingText: qsTr("Shinobi Installation Wizard")
        bodyText: qsTr("This installs the system you are running now onto a disk.<br/>" +
                        "The same packages, the same desktop, the same fonts — nothing is<br/>" +
                        "downloaded, so it works with no network at all.")
    }

    ShinobiSlide {
        headingText: qsTr("The base is Kali, unmodified")
        bodyText: qsTr("Shinobi is a layer on Kali's tool suite, kernel and archive.<br/>" +
                        "It does not fork it and it does not replace it: the base keeps<br/>" +
                        "receiving Kali's updates, and the AI layer sits on top.")
    }

    ShinobiSlide {
        headingText: qsTr("You are installing the control plane too")
        bodyText: qsTr("The agent daemon, the context service and the recon MCP server<br/>" +
                        "come across with the system. They are what every coding agent's<br/>" +
                        "tool calls go through, behind the engagement's scope.")
    }

    ShinobiSlide {
        headingText: qsTr("You will be asked for one account")
        bodyText: qsTr("It is the only account on the installed system, and it is the one<br/>" +
                        "the desktop and the control plane run as. The live session's own<br/>" +
                        "account is not carried over.")
    }

    ShinobiSlide {
        headingText: qsTr("Encryption is offered, and it is real")
        bodyText: qsTr("If you encrypt the disk, the passphrase is collected before<br/>" +
                        "anything is written, and the installed system's initramfs is<br/>" +
                        "rebuilt to unlock it. An encrypted-looking target that is not<br/>" +
                        "encrypted is worse than no encryption at all.")
    }

    ShinobiSlide {
        headingText: qsTr("The installed system is verifiable")
        bodyText: qsTr("Afterwards, <b>/usr/share/shinobi/provenance</b> names the base, its<br/>" +
                        "version and the archive it came from, and <b>shinobi doctor</b><br/>" +
                        "reports whether the control plane is actually running.")
    }

    ShinobiSlide {
        headingText: qsTr("Nothing is committed until you say so")
        bodyText: qsTr("You choose the disk on the next page. Nothing is written until<br/>" +
                        "you confirm on the summary page, and cancelling before that point<br/>" +
                        "leaves every disk untouched.")
    }
}