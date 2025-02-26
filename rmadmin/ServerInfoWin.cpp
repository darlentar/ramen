#include "ServerInfoWidget.h"
#include "ServerInfoWin.h"

ServerInfoWin::ServerInfoWin(QString const &srvUrl, QWidget *parent) :
  SavedWindow("ServerInfoWindow", tr("Server Information"), parent)
{
  ServerInfoWidget *serverInfoWidget = new ServerInfoWidget(srvUrl, this);
  setCentralWidget(serverInfoWidget);
}
