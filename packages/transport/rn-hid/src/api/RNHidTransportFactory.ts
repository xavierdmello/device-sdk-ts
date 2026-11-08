import { Platform } from "react-native";
import type { TransportFactory } from "@ledgerhq/device-management-kit";

import { DefaultNativeModuleWrapper } from "@api/bridge/DefaultNativeModuleWrapper";
import { StubNativeModuleWrapper } from "@api/bridge/StubNativeModuleWrapper";
import { RNHidTransport } from "@api/transport/RNHidTransport";

import { NativeTransportModule } from "./bridge/NativeTransportModule";

export const RNHidTransportFactory: TransportFactory = ({
  deviceModelDataSource,
  loggerServiceFactory,
}) => {
  // iOS: USB smart-card (CCID) readers through CryptoTokenKit, see ios/.
  const isSupported = Platform.OS === "android" || Platform.OS === "ios";
  const nativeModuleWrapper = isSupported
    ? new DefaultNativeModuleWrapper({
        nativeModule: NativeTransportModule,
        deviceModelDataSource,
      })
    : new StubNativeModuleWrapper();

  return new RNHidTransport(
    isSupported,
    nativeModuleWrapper,
    loggerServiceFactory,
  );
};
