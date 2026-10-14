import DevScreenshotsCapture
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
exit(ScreenshotTool.run(Array(CommandLine.arguments.dropFirst())))
