// SPDX-License-Identifier: MIT
#include "imagefingerprints.h"
#include <QGuiApplication>
#include <QQmlComponent>
#include <QQuickImageProvider>
#include <QtTest>
#include <memory>

class Provider final : public QQuickImageProvider {
public:
    explicit Provider(ImageType type = Image) : QQuickImageProvider(type) {}
    QHash<QString, QImage> images;
    int calls = 0;
    QImage requestImage(const QString &id, QSize *size, const QSize &) override {
        ++calls;
        const QImage image = images.value(id);
        *size = image.size();
        return image;
    }
    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &) override {
        ++calls;
        const QImage image = images.value(id);
        *size = image.size();
        return QPixmap::fromImage(image);
    }
};

static QImage colored(QColor color = QColor(17, 51, 255), int width = 2, int height = 2) {
    QImage image(width, height, QImage::Format_RGBA8888);
    image.fill(color);
    return image;
}

class FingerprintTests final : public QObject {
    Q_OBJECT
private slots:
    void contentRatherThanHandle() {
        QQmlEngine engine;
        auto *provider = new Provider;
        provider->images.insert("1/2", colored());
        provider->images.insert("7/8", colored());
        provider->images.insert("7/9", colored(Qt::red));
        engine.addImageProvider("qsimage", provider);
        NerdOS::ImageFingerprints fingerprints(&engine);
        const QString first = fingerprints.fingerprint("image://qsimage/1/2");
        QVERIFY(QRegularExpression("^sha256:[0-9a-f]{64}$").match(first).hasMatch());
        QCOMPARE(first, fingerprints.fingerprint("image://qsimage/7/8"));
        QVERIFY(first != fingerprints.fingerprint("image://qsimage/7/9"));
        QCOMPARE(provider->calls, 3);
        QVERIFY(fingerprints.error().isEmpty());
    }
    void dimensionsArePartOfIdentity() {
        QVERIFY(NerdOS::imageFingerprint(colored(Qt::red, 1, 2))
            != NerdOS::imageFingerprint(colored(Qt::red, 2, 1)));
    }
    void canonicalFormatsMatch() {
        const QImage image = colored();
        for (auto format : {QImage::Format_ARGB32, QImage::Format_RGB32,
                QImage::Format_ARGB32_Premultiplied, QImage::Format_RGB888})
            QCOMPARE(NerdOS::imageFingerprint(image), NerdOS::imageFingerprint(image.convertToFormat(format)));
    }
    void paddingIsExcluded() {
        QByteArray first(32, char(0x11)), second(40, char(0x77));
        QImage a(reinterpret_cast<uchar *>(first.data()), 2, 2, 16, QImage::Format_RGBA8888);
        QImage b(reinterpret_cast<uchar *>(second.data()), 2, 2, 20, QImage::Format_RGBA8888);
        // Do not use fill(), which may also initialize padding.
        for (int y = 0; y < 2; ++y)
            for (int x = 0; x < 2; ++x) {
                a.setPixelColor(x, y, QColor(1, 2, 3, 127));
                b.setPixelColor(x, y, QColor(1, 2, 3, 127));
            }
        QCOMPARE(NerdOS::imageFingerprint(a), NerdOS::imageFingerprint(b));
        QCOMPARE(first.at(8), char(0x11));
        QCOMPARE(second.at(8), char(0x77));
    }
    void unsupportedSourcesNeverFetch() {
        QQmlEngine engine;
        auto *provider = new Provider;
        engine.addImageProvider("qsimage", provider);
        NerdOS::ImageFingerprints fingerprints(&engine);
        const QStringList sources = {"", "/tmp/image", "file:///tmp/image", "https://example.org/x",
            "image://other/1/2", "image://qsimage/1", "image://qsimage/1/2?x", "image://qsimage/1/2#x",
            "image://qsimage/../2", "image://qsimage/1/%32", "image://QSIMAGE/1/2",
            "image://qsimage/-1/2", "image://qsimage/1/2\n", "image://qsimage/123456789012345678901/1"};
        for (const auto &source : sources) {
            QVERIFY2(fingerprints.fingerprint(source).isEmpty(), qPrintable(source));
            QCOMPARE(fingerprints.error(), "unsupported-source");
        }
        QCOMPARE(provider->calls, 0);
    }
    void unavailableAndNull() {
        QQmlEngine engine;
        NerdOS::ImageFingerprints fingerprints(&engine);
        QVERIFY(fingerprints.fingerprint("image://qsimage/1/2").isEmpty());
        QCOMPARE(fingerprints.error(), "provider-unavailable");
        engine.addImageProvider("qsimage", new Provider);
        QVERIFY(fingerprints.fingerprint("image://qsimage/1/2").isEmpty());
        QCOMPARE(fingerprints.error(), "image-null");
        engine.removeImageProvider("qsimage");
        engine.addImageProvider("qsimage", new Provider(QQuickImageProvider::Texture));
        QVERIFY(fingerprints.fingerprint("image://qsimage/1/2").isEmpty());
        QCOMPARE(fingerprints.error(), "unsupported-provider");
    }
    void dimensionAndStorageBounds() {
        QString error;
        QVERIFY(NerdOS::imageFingerprint(colored(Qt::red, 4097, 1), &error).isEmpty());
        QCOMPARE(error, "image-bounds");
        QVERIFY(NerdOS::imageFingerprint(colored(Qt::red, 2049, 2049), &error).isEmpty());
        QCOMPARE(error, "image-bounds");
        const int stride = NerdOS::ImageByteLimit / 2 + 4;
        QByteArray bytes(stride * 2, char(0));
        QImage padded(reinterpret_cast<uchar *>(bytes.data()), 1, 2, stride, QImage::Format_RGBA8888);
        QVERIFY(!padded.isNull());
        QVERIFY(NerdOS::imageFingerprint(padded, &error).isEmpty());
        QCOMPARE(error, "image-bounds");
    }
    void pixmapProvider() {
        QQmlEngine engine;
        auto *provider = new Provider(QQuickImageProvider::Pixmap);
        provider->images.insert("1/2", colored());
        engine.addImageProvider("qsimage", provider);
        NerdOS::ImageFingerprints fingerprints(&engine);
        QCOMPARE(fingerprints.fingerprint("image://qsimage/1/2"), NerdOS::imageFingerprint(colored()));
    }
    void realQmlSingletonUsesItsEngineProvider() {
        QQmlEngine engine;
        engine.addImportPath(QStringLiteral(TEST_QML_PATH));
        auto *provider = new Provider;
        provider->images.insert("1/2", colored());
        engine.addImageProvider("qsimage", provider);
        QQmlComponent component(&engine);
        component.setData("import QtQml\nimport NerdOS.Images 1.0\nQtObject { property string identity: ImageFingerprints.fingerprint(\"image://qsimage/1/2\") }", QUrl());
        std::unique_ptr<QObject> object(component.create());
        QVERIFY2(object, qPrintable(component.errorString()));
        QCOMPARE(object->property("identity").toString(), NerdOS::imageFingerprint(colored()));
        QCOMPARE(provider->calls, 1);
    }
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    FingerprintTests tests;
    return QTest::qExec(&tests, argc, argv);
}
#include "tests.moc"
