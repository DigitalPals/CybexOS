// SPDX-License-Identifier: MIT
#pragma once
#include <QImage>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>

namespace NerdOS {
constexpr qint64 ImageByteLimit = 16 * 1024 * 1024;
constexpr int ImageDimensionLimit = 4096;
// Hash dimensions and canonical RGBA pixels. Never retains the input image.
QString imageFingerprint(const QImage &image, QString *error = nullptr);

class ImageFingerprints final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
public:
    explicit ImageFingerprints(QQmlEngine *engine);
    Q_INVOKABLE QString fingerprint(const QString &source);
    QString error() const { return m_error; }
signals:
    void errorChanged();
private:
    QString fail(const QString &error);
    QPointer<QQmlEngine> m_engine;
    QString m_error;
};
}
