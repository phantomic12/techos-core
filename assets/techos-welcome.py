#!/usr/bin/env python3
"""TechOS Welcome GUI - lightweight PyQt/zenity fallback."""
import sys
import subprocess


def has_qt():
    try:
        from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QLabel, QPushButton
        return True
    except Exception:
        return False


def zenity_welcome():
    subprocess.run([
        "zenity", "--info",
        "--title=Welcome to TechOS",
        "--text=Welcome to TechOS Core!\n\n"
                "• Waterfox with uBlock Origin\n"
                "• Xfce Windows-style desktop\n"
                "• Audacity + PipeWire\n"
                "• Driver fetcher in the menu"
    ])


def qt_welcome():
    from PyQt5.QtWidgets import QApplication, QWidget, QVBoxLayout, QLabel, QPushButton
    app = QApplication(sys.argv)
    w = QWidget()
    w.setWindowTitle("Welcome to TechOS")
    w.setMinimumSize(400, 220)
    layout = QVBoxLayout()
    title = QLabel("<h1>Welcome to TechOS Core</h1>")
    body = QLabel("• Waterfox with uBlock Origin<br>"
                  "• Xfce Windows-style desktop<br>"
                  "• Audacity + PipeWire<br>"
                  "• Driver fetcher in the menu")
    body.setWordWrap(True)
    ok = QPushButton("Get Started")
    ok.clicked.connect(w.close)
    layout.addWidget(title)
    layout.addWidget(body)
    layout.addWidget(ok)
    w.setLayout(layout)
    w.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    if has_qt():
        qt_welcome()
    else:
        zenity_welcome()
