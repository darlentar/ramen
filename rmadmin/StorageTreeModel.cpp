#include <QDebug>
#include "StorageTreeModel.h"
#include "FunctionItem.h"
#include "GraphModel.h"

static bool verbose = true;

StorageTreeModel::StorageTreeModel(QObject *parent) :
  QSortFilterProxyModel(parent)
{
  setRecursiveFilteringEnabled(true);
}

bool StorageTreeModel::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
  if (! sourceParent.isValid()) return false;

  GraphModel *graphModel = static_cast<GraphModel *>(sourceModel());
  QModelIndex const index = graphModel->index(sourceRow, 0, sourceParent);
  GraphItem const *graphItem = graphModel->itemOfIndex(index);
  FunctionItem const *functionItem =
    dynamic_cast<FunctionItem const *>(graphItem);
  if (! functionItem) {
    if (verbose)
      qDebug() << "StorageTreeModel: Item" << graphItem->shared->name
               << "is not a function";
    return false;
  }
  std::shared_ptr<Function const> shr =
    std::static_pointer_cast<Function const>(functionItem->shared);
  if (! shr) {
    if (verbose)
      qDebug() << "StorageTreeModel: Function has no shared data!?";
    return false;
  }
  if (! shr->archivedTimes || shr->archivedTimes->isEmpty()) {
    if (verbose)
      qDebug() << "StorageTreeModel: Function" << shr->name
               << "has no archives";
    return false;
  }

  if (verbose)
    qDebug() << "StorageTreeModel: Function" << shr->name
             << "has archives!";
  return true;
}
