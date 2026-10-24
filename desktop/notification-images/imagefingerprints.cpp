// SPDX-License-Identifier: MIT
#include "imagefingerprints.h"
#include <QCryptographicHash>
#include <QQuickImageProvider>
#include <QRegularExpression>
#include <QThread>
#include <QtEndian>

namespace CybexOS {
namespace {
bool boundedDimensions(int width, int height) {
    return width > 0 && height > 0 && width <= ImageDimensionLimit
        && height <= ImageDimensionLimit && qint64(width) * height * 4 <= ImageByteLimit;
}
}

QString imageFingerprint(const QImage &image, QString *error) {
    const auto fail = [error](const QString &why) {
        if (error) *error = why;
        return QString();
    };
    if (image.isNull()) return fail(QStringLiteral("image-null"));
    // Check original storage AND canonical size before allocating conversion.
    if (!boundedDimensions(image.width(), image.height()) || image.sizeInBytes() > ImageByteLimit)
        return fail(QStringLiteral("image-bounds"));
    const QImage rgba = image.convertToFormat(QImage::Format_RGBA8888);
    if (rgba.isNull()) return fail(QStringLiteral("canonicalization-failed"));
    if (rgba.sizeInBytes() > ImageByteLimit) return fail(QStringLiteral("image-bounds"));
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(QByteArrayView("CybexOS.NotificationImage.RGBA.v1"));
    const quint32 dimensions[] = {qToBigEndian(quint32(rgba.width())), qToBigEndian(quint32(rgba.height()))};
    hash.addData(QByteArrayView(reinterpret_cast<const char *>(dimensions), sizeof(dimensions)));
    for (int y = 0; y < rgba.height(); ++y)
        hash.addData(QByteArrayView(reinterpret_cast<const char *>(rgba.constScanLine(y)), qsizetype(rgba.width()) * 4));
    if (error) error->clear();
    return QStringLiteral("sha256:") + QString::fromLatin1(hash.result().toHex());
}

ImageFingerprints::ImageFingerprints(QQmlEngine *engine) : QObject(engine), m_engine(engine) {}

QString ImageFingerprints::fail(const QString &error) {
    if (m_error != error) { m_error = error; emit errorChanged(); }
    return {};
}

QString ImageFingerprints::fingerprint(const QString &source) {
    // No URL parser canonicalization, file loading, network or arbitrary provider.
    static const QRegularExpression allowed(QStringLiteral("\\Aimage://qsimage/[0-9]{1,20}/[0-9]{1,20}\\z"));
    if (source.size() > 64 || !allowed.match(source).hasMatch())
        return fail(QStringLiteral("unsupported-source"));
    if (!m_engine) return fail(QStringLiteral("engine-unavailable"));
    if (QThread::currentThread() != m_engine->thread()) return fail(QStringLiteral("wrong-thread"));
    auto *provider = dynamic_cast<QQuickImageProvider *>(m_engine->imageProvider(QStringLiteral("qsimage")));
    if (!provider) return fail(QStringLiteral("provider-unavailable"));
    const QString id = source.mid(16); // exact "image://qsimage/" prefix
    QSize size;
    QImage image;
    if (provider->imageType() == QQmlImageProviderBase::Image) {
        image = provider->requestImage(id, &size, QSize());
    } else if (provider->imageType() == QQmlImageProviderBase::Pixmap) {
        const QPixmap pixmap = provider->requestPixmap(id, &size, QSize());
        if (pixmap.isNull()) return fail(QStringLiteral("image-null"));
        // QPixmap has no public byte-stride API. Bound dimensions and bit
        // depth before asking Qt for a CPU image; recheck actual storage next.
        if (!boundedDimensions(pixmap.width(), pixmap.height())
                || qint64(pixmap.width()) * pixmap.height() * qMax(1, pixmap.depth()) / 8 > ImageByteLimit)
            return fail(QStringLiteral("image-bounds"));
        image = pixmap.toImage();
    } else {
        return fail(QStringLiteral("unsupported-provider"));
    }
    QString error;
    const QString identity = imageFingerprint(image, &error);
    fail(error);
    return identity;
}
}
