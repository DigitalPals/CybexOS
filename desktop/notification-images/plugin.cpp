// SPDX-License-Identifier: MIT
#include "imagefingerprints.h"
#include <QQmlExtensionPlugin>
#include <qqml.h>

class NotificationImagesPlugin final : public QQmlExtensionPlugin {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid)
public:
    void registerTypes(const char *uri) override {
        qmlRegisterSingletonType<CybexOS::ImageFingerprints>(uri, 1, 0, "ImageFingerprints",
            [](QQmlEngine *engine, QJSEngine *) -> QObject * {
                return new CybexOS::ImageFingerprints(engine);
            });
    }
};
#include "plugin.moc"
