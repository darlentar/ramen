#ifndef BUTTONDELEGATE_H_190802
#define BUTTONDELEGATE_H_190802
#include <QStyledItemDelegate>
#include <QRect>

/* This is the whole dance one have to perform to add a mere button into
 * a QTreeView.
 * QTreeWidget has simpler ways, but that are repeatedly discouraged for
 * being too slow.
 *
 * Largely inspired by:
 *
 * https://doc.qt.io/qt-5/qtwidgets-itemviews-stardelegate-example.html
 * https://stackoverflow.com/questions/7175333/how-to-create-delegate-for-qtreewidget
 */

class QPixmap;

class ButtonDelegate : public QStyledItemDelegate
{
  Q_OBJECT

  int margin;

  Q_DISABLE_COPY(ButtonDelegate);
public:
  ButtonDelegate(
    unsigned margin = 0,
    QObject *parent = nullptr);

  QRect rect(QPixmap const &, QStyleOptionViewItem const &) const;
  void paint(QPainter *, QStyleOptionViewItem const &, QModelIndex const &) const;
  QSize sizeHint(QStyleOptionViewItem const &, QModelIndex const &) const;
  bool editorEvent(QEvent *, QAbstractItemModel *, QStyleOptionViewItem const &, QModelIndex const &);

signals:
  void clicked(QModelIndex const &);
  void hovered(QModelIndex const &);

};

#endif
