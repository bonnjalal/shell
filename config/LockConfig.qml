import Quickshell.Io

JsonObject {
    property bool recolourLogo: false
    property bool enableFprint: true
    property int maxFprintTries: 3
    property bool enableHowdy: true
    // property int maxHowdyTries: 3 // for howdy to work Continually  it should not have a max tries.
    property Sizes sizes: Sizes {}

    component Sizes: JsonObject {
        property real heightMult: 0.7
        property real ratio: 16 / 9
        property int centerWidth: 600
    }
}
